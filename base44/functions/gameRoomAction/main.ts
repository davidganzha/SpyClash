import { createClient, createClientFromRequest } from 'npm:@base44/sdk@0.8.31';

function jsonError(message, status = 400) {
  return Response.json({ error: message }, { status });
}

function clean(value) {
  return String(value || '').trim();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function uniqueStrings(values) {
  return [...new Set((values || []).map(clean).filter(Boolean))];
}

function normalizedStatus(room) {
  return clean(room?.status || 'waiting').toLowerCase();
}

function players(room) {
  return Array.isArray(room?.players) ? room.players : [];
}

function spectators(room) {
  return Array.isArray(room?.spectators) ? room.spectators : [];
}

function voteRequests(room) {
  return Array.isArray(room?.vote_requests) ? room.vote_requests : [];
}

function detectiveVotes(room) {
  return Array.isArray(room?.detective_votes) ? room.detective_votes : [];
}

function readyPlayers(room) {
  return Array.isArray(room?.ready_players) ? room.ready_players : [];
}

function cardsRead(room) {
  return Array.isArray(room?.cards_read) ? room.cards_read : [];
}

function activePlayers(room) {
  const out = new Set(spectators(room));
  return players(room).filter((player) => !out.has(player.email));
}

function playerInRoom(room, email) {
  return players(room).some((player) => player.email === email);
}

function playerFromUser(user, body = {}) {
  const incoming = body?.player || {};
  return {
    email: user.email,
    name: clean(incoming.name) || clean(user.display_name) || clean(user.full_name) || user.email,
    avatar: clean(incoming.avatar) || clean(user.avatar) || '🕵️'
  };
}

function mergePlayers(existingPlayers, player) {
  const byEmail = new Map();
  for (const existing of existingPlayers || []) {
    if (clean(existing?.email)) {
      byEmail.set(existing.email, existing);
    }
  }
  byEmail.set(player.email, { ...(byEmail.get(player.email) || {}), ...player, email: player.email });
  return [...byEmail.values()];
}

function requirePlayer(room, user) {
  if (!playerInRoom(room, user.email)) {
    throw Object.assign(new Error('Not a player in this room'), { status: 403 });
  }
}

function requireHost(room, user) {
  if (room?.host_email !== user.email) {
    throw Object.assign(new Error('Host access required'), { status: 403 });
  }
}

function displayWord(room) {
  return clean(room?.word) || clean(room?.secret_word);
}

function shouldSpyWin(room) {
  const spyEmail = clean(room?.spy_email);
  if (!spyEmail) return false;

  const active = activePlayers(room);
  if (!active.some((player) => player.email === spyEmail)) return false;

  const detectiveCount = active.filter((player) => player.email !== spyEmail).length;
  return detectiveCount <= 1;
}

function parseAssociationState(raw) {
  try {
    const parsed = JSON.parse(String(raw || ''));
    return {
      spoken: Array.isArray(parsed?.spoken) ? parsed.spoken : [],
      spinning: Boolean(parsed?.spinning)
    };
  } catch {
    return { spoken: [], spinning: false };
  }
}

function encodeAssociationState(state) {
  return JSON.stringify({
    spoken: Array.isArray(state?.spoken) ? state.spoken : [],
    spinning: Boolean(state?.spinning)
  });
}

async function fetchRoom(base44, roomId) {
  const rooms = await base44.asServiceRole.entities.GameRoom.filter({ id: roomId });
  return rooms?.[0] || null;
}

async function fetchRoomByCode(base44, roomCode) {
  const code = clean(roomCode).toUpperCase();
  if (!code) return null;
  const rooms = await base44.asServiceRole.entities.GameRoom.filter({ code });
  return rooms?.[0] || null;
}

async function updateRoom(base44, room, data) {
  await base44.asServiceRole.entities.GameRoom.update(room.id, data);
  return await fetchRoom(base44, room.id);
}

async function updateRoomWithRetry(base44, room, buildPatch, verify, attempts = 6) {
  let latest = room;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    latest = await fetchRoom(base44, latest.id);
    if (!latest) {
      throw Object.assign(new Error('Room not found'), { status: 404 });
    }

    const patch = buildPatch(latest) || {};
    if (!Object.keys(patch).length) {
      return latest;
    }

    await base44.asServiceRole.entities.GameRoom.update(latest.id, patch);
    latest = await fetchRoom(base44, latest.id);

    if (!verify || verify(latest)) {
      return latest;
    }

    await delay(20 + attempt * 35);
  }

  return latest;
}

async function deleteRoom(base44, room) {
  await base44.asServiceRole.entities.GameRoom.delete(room.id);
  return { success: true };
}

function randomRoomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return [...bytes].map((byte) => alphabet[byte % alphabet.length]).join('');
}

async function generateUniqueRoomCode(base44) {
  for (let attempt = 0; attempt < 16; attempt += 1) {
    const code = randomRoomCode();
    const existing = await base44.asServiceRole.entities.GameRoom.filter({ code });
    if (!existing?.length) {
      return code;
    }
  }

  throw Object.assign(new Error('Unable to generate room code'), { status: 503 });
}

async function archiveRoomResult(base44, room, winner) {
  const roomPlayers = players(room);
  if (!roomPlayers.length) return;

  const existing = await base44.asServiceRole.entities.GameHistory.filter({ room_code: room.code });
  const archivedEmails = new Set(
    (existing || []).map((record) => clean(record?.player_email)).filter(Boolean)
  );

  for (const player of roomPlayers) {
    if (archivedEmails.has(player.email)) continue;

    const isSpy = player.email === room.spy_email;
    const won = winner === 'spy' ? isSpy : !isSpy;
    await base44.asServiceRole.entities.GameHistory.create({
      player_email: player.email,
      room_code: room.code,
      match_type: 'online',
      ranked: true,
      role: isSpy ? 'spy' : 'detective',
      word: displayWord(room) || 'CLASSIFIED',
      category: clean(room.category) || 'CLASSIC',
      winner,
      player_count: roomPlayers.length,
      won
    });
  }
}

async function recordFinishedOnlineGame(base44, room, user) {
  requirePlayer(room, user);

  const winner = clean(room?.winner).toLowerCase();
  if (normalizedStatus(room) !== 'finished' || !['spy', 'detectives'].includes(winner)) {
    throw Object.assign(new Error('Only a finished online room can be ranked'), { status: 409 });
  }

  await archiveRoomResult(base44, room, winner);
  return await fetchRoom(base44, room.id);
}

async function finishRoom(base44, room, winner) {
  const finished = await updateRoom(base44, room, {
    status: 'finished',
    winner
  });
  await archiveRoomResult(base44, finished, winner);
  return finished;
}

async function createRoom(base44, user, body) {
  const player = playerFromUser(user, body);
  const code = await generateUniqueRoomCode(base44);

  return await base44.asServiceRole.entities.GameRoom.create({
    code,
    host_email: user.email,
    status: 'waiting',
    players: [player],
    game_mode: 'questions',
    game_duration_seconds: 900,
    ready_players: [],
    winner: ''
  });
}

async function joinRoom(base44, room, user, body) {
  const player = playerFromUser(user, body);
  if (playerInRoom(room, user.email)) {
    return room;
  }
  if (normalizedStatus(room) !== 'waiting') {
    throw Object.assign(new Error('Room is no longer accepting operatives'), { status: 409 });
  }
  if (players(room).length >= 12) {
    throw Object.assign(new Error('Room is full'), { status: 409 });
  }
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      if (playerInRoom(latest, user.email)) {
        return {};
      }
      if (normalizedStatus(latest) !== 'waiting' || players(latest).length >= 12) {
        throw Object.assign(new Error('Room is no longer accepting operatives'), { status: 409 });
      }
      return {
        players: mergePlayers(players(latest), player)
      };
    },
    (latest) => playerInRoom(latest, user.email)
  );
}

async function beginReadyCheck(base44, room, user) {
  requireHost(room, user);
  if (normalizedStatus(room) !== 'waiting') {
    throw Object.assign(new Error('Ready check can only start from the lobby'), { status: 409 });
  }
  if (players(room).length < 3) {
    throw Object.assign(new Error('Need at least 3 operatives'), { status: 400 });
  }
  return await updateRoom(base44, room, {
    status: 'ready_voting',
    ready_players: []
  });
}

async function returnToWaiting(base44, room, user) {
  requireHost(room, user);
  if (normalizedStatus(room) !== 'ready_voting') {
    throw Object.assign(new Error('Room is not in ready check'), { status: 409 });
  }
  return await updateRoom(base44, room, {
    status: 'waiting',
    ready_players: []
  });
}

async function toggleReady(base44, room, user) {
  requirePlayer(room, user);
  if (normalizedStatus(room) !== 'ready_voting') {
    throw Object.assign(new Error('Ready check is not active'), { status: 409 });
  }
  const shouldBeReady = !readyPlayers(room).includes(user.email);

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const ready = readyPlayers(latest);
      const nextReady = shouldBeReady
        ? uniqueStrings([...ready, user.email])
        : ready.filter((email) => email !== user.email);
      return { ready_players: nextReady };
    },
    (latest) => readyPlayers(latest).includes(user.email) === shouldBeReady
  );
}

async function votePlayAgain(base44, room, user) {
  requirePlayer(room, user);
  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const ready = readyPlayers(latest);
      return ready.includes(user.email) ? {} : { ready_players: uniqueStrings([...ready, user.email]) };
    },
    (latest) => readyPlayers(latest).includes(user.email)
  );
}

async function resetRoomForReplay(base44, room, user, body) {
  requireHost(room, user);
  return await updateRoom(base44, room, {
    status: 'waiting',
    spy_email: '',
    secret_word: '',
    word: '',
    category: '',
    spy_guess: '',
    detective_votes: [],
    winner: '',
    cards_read: [],
    vote_requests: [],
    spectators: [],
    eliminated_emails: [],
    ready_players: [],
    question_phase: 'asking',
    questions_in_round: 0,
    round_number: 1,
    current_answer: '',
    current_answer_feedback: null,
    current_asker_email: '',
    current_answerer_email: '',
    roulette_target_email: '',
    player_feedback: [],
    word_pool: [],
    game_started_at: null,
    countdown_started_at: null,
    game_mode: clean(body?.game_mode) || clean(room.game_mode) || 'questions',
    game_duration_seconds: Number(body?.game_duration_seconds || room.game_duration_seconds || 900)
  });
}

async function updateGameMode(base44, room, user, body) {
  requireHost(room, user);
  if (normalizedStatus(room) !== 'waiting') {
    throw Object.assign(new Error('Game mode can only change in the lobby'), { status: 409 });
  }
  const mode = clean(body?.mode);
  if (!['questions', 'associations'].includes(mode)) {
    throw Object.assign(new Error('Invalid game mode'), { status: 400 });
  }
  return await updateRoom(base44, room, { game_mode: mode });
}

async function updateGameDuration(base44, room, user, body) {
  requireHost(room, user);
  if (normalizedStatus(room) !== 'waiting') {
    throw Object.assign(new Error('Duration can only change in the lobby'), { status: 409 });
  }

  const durationSeconds = Number(body?.game_duration_seconds);
  if (!Number.isInteger(durationSeconds) || durationSeconds < 60 || durationSeconds > 900) {
    throw Object.assign(new Error('Duration must be between 1 and 15 minutes'), { status: 400 });
  }

  return await updateRoom(base44, room, { game_duration_seconds: durationSeconds });
}

function validatedStartPatch(room, payload) {
  const roomPlayers = players(room);
  const emails = new Set(roomPlayers.map((player) => player.email));
  const spyEmail = clean(payload?.spy_email);
  const askerEmail = clean(payload?.current_asker_email);
  const answererEmail = clean(payload?.current_answerer_email);
  const secretWord = clean(payload?.word || payload?.secret_word);
  const gameMode = clean(payload?.game_mode);
  const durationSeconds = Number(payload?.game_duration_seconds);
  const wordPool = Array.isArray(payload?.word_pool)
    ? payload.word_pool
        .map((entry) => ({ word: clean(entry?.word), enabled: entry?.enabled !== false }))
        .filter((entry) => entry.word)
        .slice(0, 500)
    : [];

  if (roomPlayers.length < 3) {
    throw Object.assign(new Error('Need at least 3 operatives'), { status: 400 });
  }
  if (!emails.has(spyEmail)) {
    throw Object.assign(new Error('Spy must be a room player'), { status: 400 });
  }
  if (!emails.has(askerEmail) || !emails.has(answererEmail) || askerEmail === answererEmail) {
    throw Object.assign(new Error('Question vector must use two room players'), { status: 400 });
  }
  if (!secretWord) {
    throw Object.assign(new Error('Secret word is required'), { status: 400 });
  }
  if (!['questions', 'associations'].includes(gameMode)) {
    throw Object.assign(new Error('Invalid game mode'), { status: 400 });
  }
  if (!Number.isInteger(durationSeconds) || durationSeconds < 60 || durationSeconds > 900) {
    throw Object.assign(new Error('Duration must be between 1 and 15 minutes'), { status: 400 });
  }
  if (wordPool.length < 2 || !wordPool.some((entry) => entry.word === secretWord)) {
    throw Object.assign(new Error('Word pool is invalid'), { status: 400 });
  }

  return {
    spy_email: spyEmail,
    secret_word: secretWord,
    word: secretWord,
    category: clean(payload?.category) || 'CLASSIC',
    round_number: 1,
    questions_in_round: 0,
    current_asker_email: askerEmail,
    current_answerer_email: answererEmail,
    game_duration_seconds: durationSeconds,
    question_phase: 'asking',
    current_answer: '',
    current_answer_feedback: null,
    spy_guess: '',
    player_feedback: [],
    word_pool: wordPool,
    game_mode: gameMode
  };
}

async function armRoulette(base44, room, user, body) {
  requireHost(room, user);
  const roomPlayers = players(room);
  const status = normalizedStatus(room);
  if (!['waiting', 'ready_voting'].includes(status)) {
    throw Object.assign(new Error('Mission can only start from the lobby'), { status: 409 });
  }
  if (roomPlayers.length < 3) {
    throw Object.assign(new Error('Need at least 3 operatives'), { status: 400 });
  }
  if (status === 'ready_voting' && !roomPlayers.every((player) => readyPlayers(room).includes(player.email))) {
    throw Object.assign(new Error('All operatives must be ready'), { status: 409 });
  }

  const target = clean(body?.roulette_target_email) || roomPlayers[0]?.email;
  if (!roomPlayers.some((player) => player.email === target)) {
    throw Object.assign(new Error('Roulette target is not in this room'), { status: 400 });
  }

  const startPatch = validatedStartPatch(room, body?.plan || {});
  return await updateRoom(base44, room, {
    ...startPatch,
    status: 'roulette',
    roulette_target_email: target
  });
}

async function completeGameStart(base44, room, user, body) {
  requireHost(room, user);
  if (normalizedStatus(room) !== 'roulette') {
    throw Object.assign(new Error('Mission is not armed'), { status: 409 });
  }

  const startPatch = body?.plan ? validatedStartPatch(room, body.plan) : {};

  return await updateRoom(base44, room, {
    ...startPatch,
    status: 'playing',
    game_started_at: new Date().toISOString(),
    ready_players: [],
    cards_read: [],
    vote_requests: [],
    detective_votes: [],
    spectators: [],
    eliminated_emails: [],
    winner: ''
  });
}

async function markRoleCardRead(base44, room, user) {
  requirePlayer(room, user);
  const updatedReadRoom = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const read = cardsRead(latest);
      return read.includes(user.email) ? {} : { cards_read: uniqueStrings([...read, user.email]) };
    },
    (latest) => cardsRead(latest).includes(user.email)
  );

  const allCardsRead = players(updatedReadRoom).length > 0
    && players(updatedReadRoom).every((player) => cardsRead(updatedReadRoom).includes(player.email));

  if (!allCardsRead) {
    return updatedReadRoom;
  }

  const updated = await updateRoom(base44, updatedReadRoom, {
    cards_read: cardsRead(updatedReadRoom),
    ready_players: [],
    game_started_at: new Date().toISOString(),
    game_duration_seconds: Number(updatedReadRoom.game_duration_seconds || 900)
  });

  if (shouldSpyWin(updated)) {
    return await finishRoom(base44, updated, 'spy');
  }

  return updated;
}

async function advanceQuestion(base44, room, user) {
  requirePlayer(room, user);
  const active = activePlayers(room);
  if (active.length < 2) {
    throw Object.assign(new Error('Need at least 2 active operatives'), { status: 400 });
  }

  const nextQuestions = Number(room.questions_in_round || 0) + 1;
  if (nextQuestions >= 8) {
    return await updateRoom(base44, room, { question_phase: 'results' });
  }

  const currentAnswererIndex = Math.max(0, active.findIndex((player) => player.email === room.current_answerer_email));
  const nextAskerIndex = currentAnswererIndex;
  let nextAnswererIndex = (currentAnswererIndex + 1) % active.length;
  if (nextAnswererIndex === nextAskerIndex) {
    nextAnswererIndex = (nextAnswererIndex + 1) % active.length;
  }

  return await updateRoom(base44, room, {
    current_asker_email: active[nextAskerIndex].email,
    current_answerer_email: active[nextAnswererIndex].email,
    questions_in_round: nextQuestions,
    current_answer: '',
    question_phase: 'asking'
  });
}

async function advanceAssociation(base44, room, user) {
  requirePlayer(room, user);
  const active = activePlayers(room);
  if (!active.length) {
    throw Object.assign(new Error('Need active operatives'), { status: 400 });
  }

  const state = parseAssociationState(room.current_answer);
  const spoken = [...state.spoken];
  if (room.current_asker_email && !spoken.includes(room.current_asker_email)) {
    spoken.push(room.current_asker_email);
  }

  const remaining = active.filter((player) => !spoken.includes(player.email));
  const startsNewRound = remaining.length === 0;
  const pool = startsNewRound ? active : remaining;
  const nextSpeaker = pool[Math.floor(Math.random() * pool.length)] || active[0];
  const nextRound = startsNewRound ? Number(room.round_number || 1) + 1 : Number(room.round_number || 1);

  return await updateRoom(base44, room, {
    round_number: nextRound,
    current_asker_email: nextSpeaker.email,
    current_answer: encodeAssociationState({ spoken: startsNewRound ? [] : spoken, spinning: true }),
    question_phase: 'asking'
  });
}

async function requestVote(base44, room, user) {
  requirePlayer(room, user);
  if (!activePlayers(room).some((player) => player.email === user.email)) {
    throw Object.assign(new Error('Spectators cannot request a vote'), { status: 403 });
  }

  if (shouldSpyWin(room)) {
    return await finishRoom(base44, room, 'spy');
  }

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const requests = voteRequests(latest);
      return requests.includes(user.email)
        ? {}
        : { vote_requests: uniqueStrings([...requests, user.email]) };
    },
    (latest) => voteRequests(latest).includes(user.email)
  );
}

async function castDetectiveVote(base44, room, user, body) {
  requirePlayer(room, user);
  const active = activePlayers(room);
  const targetEmail = clean(body?.target_email);

  if (!active.some((player) => player.email === user.email)) {
    throw Object.assign(new Error('Spectators cannot vote'), { status: 403 });
  }
  if (!active.some((player) => player.email === targetEmail)) {
    throw Object.assign(new Error('Target is no longer active'), { status: 400 });
  }

  if (shouldSpyWin(room)) {
    return await finishRoom(base44, room, 'spy');
  }

  const votedRoom = await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const votes = detectiveVotes(latest).filter((vote) => vote.voter_email !== user.email);
      votes.push({ voter_email: user.email, voted_for_email: targetEmail });
      return { detective_votes: votes };
    },
    (latest) => detectiveVotes(latest).some(
      (vote) => vote.voter_email === user.email && vote.voted_for_email === targetEmail
    )
  );

  const activeAfterVote = activePlayers(votedRoom);
  const activeEmails = new Set(activeAfterVote.map((player) => player.email));
  const votes = detectiveVotes(votedRoom).filter(
    (vote) => activeEmails.has(vote.voter_email) && activeEmails.has(vote.voted_for_email)
  );

  if (votes.length < activeAfterVote.length) {
    return votedRoom;
  }

  const counts = new Map();
  for (const vote of votes) {
    counts.set(vote.voted_for_email, (counts.get(vote.voted_for_email) || 0) + 1);
  }

  const accused = [...counts.entries()].sort((lhs, rhs) => {
    if (lhs[1] === rhs[1]) return lhs[0].localeCompare(rhs[0]);
    return rhs[1] - lhs[1];
  })[0]?.[0];

  if (accused === votedRoom.spy_email) {
    const updated = await updateRoom(base44, votedRoom, {
      detective_votes: votes,
      winner: 'detectives',
      status: 'finished'
    });
    await archiveRoomResult(base44, updated, 'detectives');
    return updated;
  }

  const nextSpectators = spectators(votedRoom);
  if (accused && !nextSpectators.includes(accused)) {
    nextSpectators.push(accused);
  }

  const updated = await updateRoom(base44, votedRoom, {
    detective_votes: [],
    vote_requests: [],
    spectators: nextSpectators
  });

  if (shouldSpyWin(updated)) {
    return await finishRoom(base44, updated, 'spy');
  }

  return updated;
}

async function submitSpyGuess(base44, room, user, body) {
  requirePlayer(room, user);
  if (user.email !== room.spy_email) {
    throw Object.assign(new Error('Only the spy can guess the word'), { status: 403 });
  }

  const guess = clean(body?.guess);
  const correct = guess.localeCompare(displayWord(room), undefined, { sensitivity: 'accent' }) === 0;
  const winner = correct ? 'spy' : 'detectives';
  const updated = await updateRoom(base44, room, {
    spy_guess: guess,
    winner,
    status: 'finished'
  });
  await archiveRoomResult(base44, updated, winner);
  return updated;
}

async function leaveRoom(base44, room, user) {
  requirePlayer(room, user);

  if (room.host_email === user.email) {
    return await deleteRoom(base44, room);
  }

  return await updateRoomWithRetry(
    base44,
    room,
    (latest) => {
      const nextPlayers = players(latest).filter((player) => player.email !== user.email);
      return {
        players: nextPlayers,
        status: nextPlayers.length === 0 && normalizedStatus(latest) === 'finished' ? 'waiting' : normalizedStatus(latest),
        spectators: spectators(latest).filter((email) => email !== user.email),
        ready_players: readyPlayers(latest).filter((email) => email !== user.email),
        cards_read: cardsRead(latest).filter((email) => email !== user.email),
        eliminated_emails: uniqueStrings(latest?.eliminated_emails).filter((email) => email !== user.email),
        vote_requests: voteRequests(latest).filter((email) => email !== user.email),
        detective_votes: detectiveVotes(latest).filter(
          (vote) => vote.voter_email !== user.email && vote.voted_for_email !== user.email
        )
      };
    },
    (latest) => !playerInRoom(latest, user.email)
  );
}

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const accessToken = clean(body?.access_token);
    const appId = req.headers.get('Base44-App-Id');
    const serverUrl = req.headers.get('Base44-Api-Url') || 'https://base44.app';

    if (!accessToken || !appId) {
      return jsonError('Unauthorized', 401);
    }

    // The function gateway does not accept every provider/SSO token as its
    // Authorization header. Verify that token directly against Base44, while
    // keeping createClientFromRequest for server-side service-role access.
    const identityClient = createClient({ appId, serverUrl, token: accessToken });
    const user = await identityClient.auth.me();
    const base44 = createClientFromRequest(req);

    if (!user?.email) {
      return jsonError('Unauthorized', 401);
    }

    const action = clean(body?.action);
    const roomId = clean(body?.room_id);

    if (!action) return jsonError('Missing action');

    if (action === 'create_room') {
      return Response.json(await createRoom(base44, user, body));
    }

    const room = roomId
      ? await fetchRoom(base44, roomId)
      : await fetchRoomByCode(base44, body?.room_code || body?.code);

    if (!room) return jsonError('Room not found', 404);

    switch (action) {
      case 'join_room':
        return Response.json(await joinRoom(base44, room, user, body));
      case 'begin_ready_check':
        return Response.json(await beginReadyCheck(base44, room, user));
      case 'return_to_waiting':
        return Response.json(await returnToWaiting(base44, room, user));
      case 'toggle_ready':
        return Response.json(await toggleReady(base44, room, user));
      case 'vote_play_again':
        return Response.json(await votePlayAgain(base44, room, user));
      case 'reset_room_for_replay':
        return Response.json(await resetRoomForReplay(base44, room, user, body));
      case 'update_game_mode':
        return Response.json(await updateGameMode(base44, room, user, body));
      case 'update_game_duration':
        return Response.json(await updateGameDuration(base44, room, user, body));
      case 'arm_roulette':
        return Response.json(await armRoulette(base44, room, user, body));
      case 'complete_game_start':
        return Response.json(await completeGameStart(base44, room, user, body));
      case 'mark_role_card_read':
        return Response.json(await markRoleCardRead(base44, room, user));
      case 'advance_question':
        return Response.json(await advanceQuestion(base44, room, user));
      case 'advance_association':
        return Response.json(await advanceAssociation(base44, room, user));
      case 'request_vote':
        return Response.json(await requestVote(base44, room, user));
      case 'cast_detective_vote':
        return Response.json(await castDetectiveVote(base44, room, user, body));
      case 'submit_spy_guess':
        return Response.json(await submitSpyGuess(base44, room, user, body));
      case 'finish_room': {
        requireHost(room, user);
        const winner = clean(body?.winner);
        if (!['spy', 'detectives'].includes(winner)) {
          return jsonError('Invalid winner');
        }
        return Response.json(await finishRoom(base44, room, winner));
      }
      case 'record_finished_online_game':
        return Response.json(await recordFinishedOnlineGame(base44, room, user));
      case 'leave_room':
        return Response.json(await leaveRoom(base44, room, user));
      default:
        return jsonError(`Unsupported action: ${action}`, 400);
    }
  } catch (error) {
    console.error('gameRoomAction error:', error?.message || error);
    return jsonError(error?.message || 'Internal error', error?.status || 500);
  }
});
