// @ts-nocheck -- Original game records have a validated dynamic wire format.
import { reduceGame, projectGame } from './engine.ts';
import { readLeaderboard } from './leaderboard-service.ts';
import { validateSharedWordPackContent } from './word-pack-content-safety.ts';
import { accountGate } from '../app-services/account-gate.ts';

export class GameServiceError extends Error {
  constructor(code, message, status = 400, retryable = false) {
    super(message); Object.assign(this, { code, status, retryable });
  }
}
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const reads = new Set(['get_room', 'get_active_room', 'get_lobby_state', 'word_packs', 'get_word_pack', 'get_history', 'get_leaderboard']);
const revisionActions = new Set(['advance_question', 'advance_association', 'start_association', 'stop_association_spin', 'mark_answer_heard', 'continue_round']);

export function canonicalJSON(value) {
  if (Array.isArray(value)) return '[' + value.map(canonicalJSON).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonicalJSON(value[k])).join(',') + '}';
  return JSON.stringify(value);
}
export async function commandHash(body) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonicalJSON(body)));
  return [...new Uint8Array(bytes)].map(v => v.toString(16).padStart(2, '0')).join('');
}
function publicError(error) {
  const status = Number(error?.status || error?.statusCode);
  if (Number.isInteger(status) && status >= 400 && status < 500) {
    return { status, body: { code: String(error.code || 'room_action_rejected'), message: String(error.message || 'Action rejected'), retryable: false } };
  }
  throw error;
}
function member(room, actor) {
  return Array.isArray(room?.players) && room.players.some(p => p.user_id === actor.id && p.email === actor.email)
    && !(room.departed_player_emails || []).includes(actor.email);
}
function visible(room, actor) {
  if (!room || room.closed === true || ['ended', 'closed'].includes(room.status) || !member(room, actor)) return null;
  return projectGame(room, actor);
}
function roomResponse(room, actor, receipt = undefined) {
  return { room: visible(room, actor), revision: Number(room?.room_revision || 0), ...(receipt ? { receipt } : {}) };
}
function validUUID(value, label) {
  if (!uuidPattern.test(String(value || ''))) throw new GameServiceError('invalid_' + label, label + ' must be a UUID.');
  return String(value).toLowerCase();
}
function packData(row) { return row ? { ...row.pack, id: row.id } : null; }
function validatePack(body) {
  const source = body.pack || body;
  return { ...validateSharedWordPackContent({ name: source.name, category: source.category, words: Array.isArray(source.words) ? source.words : [] }), is_public: false };
}

/** One connection + transaction owns command serialization and all state effects.
 * No external requests or asynchronous side effects run while the room is locked.
 * db is a postgres.js client; tests use the same service and real PostgreSQL.
 */
export async function executeGame(db, actor, body) {
  validUUID(actor.id, 'actor');
  if (actor.email !== actor.id.toLowerCase() + '@example.test') throw new GameServiceError('invalid_actor', 'Invalid test actor.', 401);
  const action = String(body?.action || '');
  if (reads.has(action)) return await db.begin(async tx => {
    actor = await gameAccountGate(tx, actor);
    return await readGame(tx, actor, body);
  });
  if (action === 'generate_word_pack') throw new GameServiceError('generation_retained_in_base44', 'AI word generation remains on Base44. This endpoint only owns gameplay and saved packs.', 424, false);
  const requestID = validUUID(body.request_id, 'request_id');
  const hash = await commandHash(body);
  return await db.begin(async tx => {
    await tx`set local statement_timeout = '8s'`;
    await tx`set local lock_timeout = '6s'`;
    actor = await gameAccountGate(tx, actor);
    await tx`select pg_advisory_xact_lock(hashtextextended(${actor.id + ':' + requestID}, 0))`;
    const [prior] = await tx`select request_hash, status, response from full_game_private.receipts where actor_id=${actor.id} and request_id=${requestID}`;
    if (prior) {
      if (prior.request_hash !== hash) return { status: 409, body: { code: 'request_id_reused', message: 'This request ID belongs to a different action.', retryable: false } };
      return { status: prior.status, body: prior.response };
    }
    let result;
    let roomID = null;
    let revision = null;
    try {
      if (['create_word_pack', 'update_word_pack', 'delete_word_pack'].includes(action)) {
        result = await mutatePack(tx, actor, body);
        result.body.receipt = { request_id: requestID, room_id: null, revision: null };
      } else {
        let stored = null;
        if (action !== 'create_room') {
          stored = await findRoom(tx, body, true);
          if (!stored) throw new GameServiceError('room_not_found', 'Room not found.', 404);
          roomID = stored.id;
          if (action !== 'join_room' && !member(stored.state, actor)) throw new GameServiceError('not_member', 'You are no longer a member of this room.', 403);
          if (stored.closed) throw new GameServiceError('room_closed', 'This room has closed.', 410);
          if (revisionActions.has(action) && Number(body.expected_revision) !== Number(stored.revision)) {
            throw new GameServiceError('room_revision_conflict', 'This turn has changed. Refresh the room before acting again.', 409);
          }
        } else {
          roomID = crypto.randomUUID();
        }
        const [{ now_ms: now }] = await tx`select extract(epoch from clock_timestamp()) * 1000 as now_ms`;
        const roomCode = stored?.code || await unusedRoomCode(tx);
        const output = reduceGame({ room: stored?.state || null, actor, action, payload: body, now: Number(now), roomID, roomCode });
        const room = output.room;
        if (!room || room.id !== roomID || room.code !== roomCode) throw new Error('Reducer returned an invalid room identity');
        revision = Number(stored?.revision || 0) + 1;
        room.room_revision = revision;
        room.updated_date = new Date(Number(now)).toISOString();
        const closed = room.closed === true || ['ended', 'closed'].includes(room.status);
        // Validate every reference before the first write: a definitive
        // reducer rejection must never commit a partially changed room.
        const roster = (Array.isArray(room.players) ? room.players : []).filter(p => !(room.departed_player_emails || []).includes(p.email));
        const ids = roster.map(p => validUUID(p.user_id, 'player_id'));
        for (const player of roster) validUUID(player.membership_id, 'membership_id');
        for (const entry of output.history || []) {
          validUUID(entry.match_id, 'match_id'); validUUID(entry.player_user_id, 'player_id');
        }
        const receipt = { request_id: requestID, room_id: roomID, revision };
        const response = roomResponse(room, actor, receipt);
        if (stored) await tx`update full_game_private.rooms set state=${tx.json(room)}, revision=${revision}, closed=${closed}, updated_at=clock_timestamp() where id=${roomID}`;
        else await tx`insert into full_game_private.rooms(id, code, revision, state, closed) values (${roomID}, ${roomCode}, ${revision}, ${tx.json(room)}, ${closed})`;
        // Synchronize membership within the same commit as roles/state/signals.
        await tx`delete from full_game_private.members where room_id=${roomID} and not (user_id = any(${ids}::uuid[]))`;
        for (const player of roster) {
          await tx`insert into full_game_private.members(room_id,user_id,membership_id) values (${roomID},${player.user_id},${validUUID(player.membership_id, 'membership_id')}) on conflict(room_id,user_id) do update set membership_id=excluded.membership_id`;
        }
        for (const entry of output.history || []) {
          await tx`insert into full_game_private.history(match_id,player_id,room_id,result) values (${validUUID(entry.match_id, 'match_id')},${validUUID(entry.player_user_id, 'player_id')},${roomID},${tx.json(entry)}) on conflict(match_id,player_id) do nothing`;
        }
        for (const [index, event] of (output.events || []).entries()) {
          const eventID = String(event.id || event.event_id || `${roomID}:${revision}:${index}`);
          await tx`insert into full_game_private.outbox(id,room_id,event) values (${eventID},${roomID},${tx.json(event)}) on conflict(id) do nothing`;
        }
        await tx`insert into public.full_game_room_signals(room_id,revision) values (${roomID},${revision}) on conflict(room_id) do update set revision=excluded.revision,updated_at=clock_timestamp()`;
        result = { status: 200, body: response };
      }
    } catch (error) {
      // Business rejections are durable too. An SQL/infrastructure failure
      // escapes this catch and rolls the entire transaction back.
      result = publicError(error);
    }
    await tx`insert into full_game_private.receipts(actor_id,request_id,request_hash,room_id,revision,status,response) values (${actor.id},${requestID},${hash},${roomID},${revision},${result.status},${tx.json(result.body)})`;
    return result;
  });
}

async function gameAccountGate(tx, actor) {
  // Standalone game-lab databases predate the full-app schema. Once installed,
  // this gate is mandatory and serializes account deletion with every command.
  const [{ installed }] = await tx`select to_regclass('app_private.profiles') is not null as installed`;
  if (!installed) return actor;
  const profile = await accountGate(tx, actor.id);
  return profile ? { ...actor,
    full_name: String(profile.data?.full_name || actor.full_name).slice(0,80),
    display_name: String(profile.data?.display_name || profile.data?.full_name || actor.full_name).slice(0,80),
    avatar: String(profile.data?.avatar || '🕵️'),
  } : actor;
}

async function findRoom(tx, body, lock = false) {
  if (body.room_id) {
    validUUID(body.room_id, 'room_id');
    return (await tx`select id,code,revision,state,closed from full_game_private.rooms where id=${body.room_id} ${lock ? tx`for update` : tx``}`)[0];
  }
  const code = String(body.room_code || '').toUpperCase().trim();
  if (!/^[A-Z0-9]{6}$/.test(code)) throw new GameServiceError('invalid_room_code', 'Enter the six-character room code.');
  return (await tx`select id,code,revision,state,closed from full_game_private.rooms where code=${code} ${lock ? tx`for update` : tx``}`)[0];
}
async function unusedRoomCode(tx) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  for (let attempt = 0; attempt < 8; attempt++) {
    const code = [...crypto.getRandomValues(new Uint8Array(6))].map(v => alphabet[v % alphabet.length]).join('');
    // Serializes the extremely rare collision without locking other rooms.
    await tx`select pg_advisory_xact_lock(hashtextextended(${'full-game-code:' + code}, 0))`;
    if (!(await tx`select 1 from full_game_private.rooms where code=${code}`).length) return code;
  }
  throw new Error('Room code generation failed');
}
async function readGame(db, actor, body) {
  if (body.action === 'word_packs') {
    const rows = await db`select id,pack from full_game_private.word_packs where owner_id=${actor.id} order by created_at desc limit 500`;
    return { status: 200, body: { packs: rows.map(packData) } };
  }
  if (body.action === 'get_word_pack') {
    const id = validUUID(body.pack_id || body.id, 'pack_id');
    const [row] = await db`select id,pack from full_game_private.word_packs where id=${id} and owner_id=${actor.id}`;
    if (!row) throw new GameServiceError('pack_not_found', 'Word pack not found.', 404);
    return { status: 200, body: { pack: packData(row) } };
  }
  if (body.action === 'get_history') {
    const limit = Math.max(1, Math.min(200, Number.isInteger(body.limit) ? body.limit : 200));
    let cursor = null;
    if (body.cursor) {
      try {
        cursor = JSON.parse(atob(String(body.cursor)));
        validUUID(cursor.id, 'cursor');
        if (typeof cursor.at !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(cursor.at) || !Number.isFinite(Date.parse(cursor.at))) throw new Error('Invalid date');
      } catch { throw new GameServiceError('invalid_cursor', 'Invalid history cursor.'); }
    }
    const rows = await db`select match_id,result,created_at,to_char(created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as cursor_at
      from full_game_private.history where player_id=${actor.id}
      ${cursor ? db`and (created_at,match_id)<(${cursor.at}::text::timestamptz,${cursor.id}::uuid)` : db``}
      order by created_at desc,match_id desc limit ${limit + 1}`;
    const page = rows.slice(0, limit), last = page.at(-1);
    return { status: 200, body: {
      history: page.map(r => ({ ...r.result, id: r.result.result_key, created_date: r.created_at })),
      next_cursor: rows.length > limit && last ? btoa(JSON.stringify({at:last.cursor_at,id:last.match_id})) : null,
    } };
  }
  if (body.action === 'get_leaderboard') {
    return { status: 200, body: await readLeaderboard(db, actor) };
  }
  let stored;
  if (body.action === 'get_active_room') {
    const rows = await db`select r.id,r.state from full_game_private.rooms r join full_game_private.members m on m.room_id=r.id where m.user_id=${actor.id} and not r.closed order by r.updated_at desc limit 100`;
    stored = rows.find(r => r.id === (body.preferred_room_id || body.room_id)) || rows[0];
  } else {
    stored = await findRoom(db, body);
    if (!stored) throw new GameServiceError('room_not_found', 'Room not found.', 404);
    if (!member(stored.state, actor)) throw new GameServiceError('not_member', 'You are no longer a member of this room.', 403);
  }
  return { status: 200, body: roomResponse(stored?.state, actor) };
}
async function mutatePack(tx, actor, body) {
  const action = body.action;
  const id = action === 'create_word_pack' ? crypto.randomUUID() : validUUID(body.pack_id || body.id, 'pack_id');
  if (action !== 'create_word_pack') {
    const rows = await tx`select id from full_game_private.word_packs where id=${id} and owner_id=${actor.id} for update`;
    if (!rows.length) throw new GameServiceError('pack_not_found', 'Word pack not found.', 404);
  }
  if (action === 'delete_word_pack') {
    await tx`delete from full_game_private.word_packs where id=${id} and owner_id=${actor.id}`;
    return { status: 200, body: { deleted: true, id } };
  }
  const pack = { id, ...validatePack(body), owner_email: actor.email };
  if (action === 'create_word_pack') await tx`insert into full_game_private.word_packs(id,owner_id,pack) values (${id},${actor.id},${tx.json(pack)})`;
  else await tx`update full_game_private.word_packs set pack=${tx.json(pack)},updated_at=clock_timestamp() where id=${id} and owner_id=${actor.id}`;
  return { status: 200, body: { pack } };
}
