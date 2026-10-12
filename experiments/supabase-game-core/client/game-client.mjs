import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

export function requireLoopback(value, label = 'URL') {
  const url = new URL(value);
  if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
    throw new Error(`${label} must point to loopback; remote environments are refused`);
  }
  return url;
}

export function localConfig(env = process.env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    throw new Error('Run the local runner: SUPABASE_URL and SUPABASE_ANON_KEY are required');
  }
  const url = requireLoopback(env.SUPABASE_URL, 'SUPABASE_URL');
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Invalid Supabase protocol');
  if (env.DATABASE_URL) requireLoopback(env.DATABASE_URL, 'DATABASE_URL');
  return { url: url.origin, anonKey: env.SUPABASE_ANON_KEY };
}

export class CommandError extends Error {
  constructor(error) {
    super(error.message);
    this.name = 'CommandError';
    this.code = error.code;
  }
}

/** Real Auth/Data API/Realtime client; credentials remain in memory only. */
export class GameClient {
  #sdk;
  #pending = new Map();
  #snapshots = new Map();
  #intents = new Map();
  #watches = new Set();
  constructor(config = localConfig(), { transportURL } = {}) {
    requireLoopback(config.url, 'Supabase URL');
    if (transportURL) requireLoopback(transportURL, 'transport URL');
    this.#sdk = createClient(config.url, config.anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: {
        fetch: (input, init) => {
          const url = new URL(typeof input === 'string' ? input : input.url ?? input);
          requireLoopback(url, 'request URL');
          if (transportURL) {
            const proxy = new URL(transportURL);
            url.protocol = proxy.protocol;
            url.host = proxy.host;
          }
          return fetch(url, { ...init, signal: init?.signal ?? AbortSignal.timeout(12_000) });
        },
      },
    });
  }

  async signUp(name = 'Player') {
    const { data, error } = await this.#sdk.auth.signUp({
      email: `game-core-${randomUUID()}@example.test`,
      password: `${randomUUID()}!Aa7`,
    });
    if (error) throw new CommandError(error);
    if (!data.session || !data.user) throw new Error('Local Auth must return a confirmed session');
    this.userID = data.user.id;
    this.name = name;
    await this.#sdk.realtime.setAuth(data.session.access_token);
    return this;
  }

  get pendingIDs() { return [...this.#pending.keys()]; }

  async command(roomID, action, payload = {}, requestID = randomUUID()) {
    const source = JSON.stringify([roomID, action, payload]);
    const prior = this.#intents.get(requestID);
    let command;
    if (prior?.source === source) {
      command = prior.command;
    } else {
      const bound = structuredClone(payload);
      const needsMember = ['set_ready', 'leave_room'].includes(action);
      const needsSettings = action === 'set_ready';
      const needsLobby = action === 'start_game' || (action === 'close_room' && !Object.hasOwn(bound, 'match_id'));
      if ((needsMember && !Object.hasOwn(bound, 'membership_id')) ||
          (needsSettings && !Object.hasOwn(bound, 'settings_revision')) ||
          (needsLobby && !Object.hasOwn(bound, 'lobby_id'))) {
        const snapshot = this.#snapshots.get(roomID) ?? await this.snapshot(roomID);
        if (needsMember && !Object.hasOwn(bound, 'membership_id')) bound.membership_id = snapshot.own_membership_id;
        if (needsSettings && !Object.hasOwn(bound, 'settings_revision')) bound.settings_revision = snapshot.settings_revision;
        if (needsLobby && !Object.hasOwn(bound, 'lobby_id')) bound.lobby_id = snapshot.lobby_id;
      }
      command = { p_request_id: requestID, p_room_id: roomID, p_action: action, p_payload: bound };
      // Bind optimistic intent once. Reconnect/retry must never silently turn
      // an old leave/ready/start into a command for a newer membership or lobby.
      this.#intents.set(requestID, { source, command });
    }
    this.#pending.set(requestID, command);
    return this.retry(requestID);
  }

  async retry(requestID) {
    const command = this.#pending.get(requestID);
    if (!command) throw new Error('No pending command with that ID');
    const { data, error } = await this.#sdk.rpc('game_command', command);
    if (error) {
      // SQL business errors are definite rejections. Transport failures remain
      // pending because the server may have committed before the response died.
      if (error.code === 'P0001') this.#pending.delete(requestID);
      throw new CommandError(error);
    }
    this.#pending.delete(requestID);
    return data;
  }

  async snapshot(roomID) {
    const { data, error } = await this.#sdk.rpc('game_snapshot', { p_room_id: roomID });
    if (error) throw new CommandError(error);
    const current = this.#snapshots.get(roomID);
    if (!current || data.revision >= current.revision) this.#snapshots.set(roomID, data);
    return data;
  }

  async signals(roomID) {
    return this.#sdk.from('game_room_signals').select('*').eq('room_id', roomID);
  }

  async privateTable(table, mutation) {
    const query = this.#sdk.schema('game_private').from(table);
    return mutation ? query.update(mutation).select('*') : query.select('*');
  }

  async watch(roomID) {
    const watch = { events: [], statuses: [], systemEvents: [], snapshots: [], errors: [], reconciliations: [], current: null };
    let active = true;
    let interval;
    let refreshInFlight;
    const refresh = (reason) => {
      if (!active) return Promise.resolve();
      if (refreshInFlight) return refreshInFlight;
      refreshInFlight = (async () => {
        try {
          const snapshot = await this.snapshot(roomID);
          if (!active) return;
          watch.snapshots.push(snapshot);
          watch.reconciliations.push({ reason, revision: snapshot.revision });
          // Concurrent or delayed fetches must never replace newer UI state.
          if (!watch.current || snapshot.revision >= watch.current.revision) watch.current = snapshot;
        } catch (error) {
          if (active) watch.errors.push(error.message);
        } finally {
          refreshInFlight = null;
        }
      })();
      return refreshInFlight;
    };
    let resolveReady, rejectReady;
    const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
    const timer = setTimeout(() => rejectReady(new Error('Realtime replication subscription timed out')), 20_000);
    const channel = this.#sdk.channel(`game-test-${roomID}-${randomUUID()}`, {
      // Phoenix channel join alone is not PostgreSQL replication readiness.
      // Have the server hold SUBSCRIBED until its actual WAL subscription is
      // active, including the first channel after a cold local stack starts.
      config: { postgres_changes_options: { wait: true, timeout: 15_000 } },
    })
      .on('system', {}, (event) => {
        if (!active) return;
        watch.systemEvents.push({ extension: event.extension, status: event.status, message: event.message });
      })
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'game_room_signals', filter: `room_id=eq.${roomID}`,
      }, (event) => {
        if (!active) return;
        watch.events.push(event);
        void refresh('signal');
      })
      .subscribe((status) => {
        if (!active) return;
        watch.statuses.push(status);
        if (status === 'SUBSCRIBED') {
          // A subscription acknowledgement is not a room-state checkpoint.
          // Always reconcile when a channel first joins or joins again.
          clearTimeout(timer);
          void refresh('subscribed').then(resolveReady);
        }
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          clearTimeout(timer);
          rejectReady(new Error(`Realtime subscription failed: ${status}`));
        }
      });
    watch.close = async () => {
      if (!active) return;
      active = false;
      clearTimeout(timer);
      clearInterval(interval);
      this.#watches.delete(watch);
      await this.#sdk.removeChannel(channel);
    };
    this.#watches.add(watch);
    try { await ready; }
    catch (error) { clearTimeout(timer); await watch.close(); throw error; }
    // Realtime remains a hint: a missing final event cannot strand the UI.
    // This interval runs only for an active room watch and shares one fetch.
    if (active) interval = setInterval(() => { void refresh('reconcile'); }, 3_000);
    return watch;
  }

  disconnectRealtimeTransport() {
    // Keep room watchers and HTTP reconciliation alive while simulating an
    // actual closed WebSocket, rather than filtering or fabricating events.
    this.#sdk.realtime.disconnect();
  }

  async disconnectRealtime() {
    await Promise.all([...this.#watches].map((watch) => watch.close()));
    await this.#sdk.removeAllChannels();
    this.#sdk.realtime.disconnect();
  }

  realtimeConnected() { return this.#sdk.realtime.isConnected(); }

  async close() {
    await this.disconnectRealtime();
    this.#sdk.auth.stopAutoRefresh();
  }
}

export async function eventually(predicate, { timeout = 12_000, message = 'Condition did not converge' } = {}) {
  const deadline = Date.now() + timeout;
  do {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 40));
  } while (Date.now() < deadline);
  throw new Error(message);
}
