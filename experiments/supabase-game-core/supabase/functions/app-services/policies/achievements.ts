import { deduplicateCompetitiveHistory } from '../../full-game-core/rules/competitive-stats.ts';

type History = Record<string, unknown>;
export type AchievementStats = { games: number; wins: number; spyWins: number; detectiveWins: number };
export type AchievementProgress = { id: string; progress: number; target: number };

const clean = (value: unknown) => String(value ?? '').trim();
const count = (value: number) => Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;

/** Only the private server history is an award source. Never accept profile-input counters. */
export function aggregateAchievementStats(records: readonly History[]): Map<string, AchievementStats> {
  const table = new Map<string, AchievementStats>();
  for (const row of deduplicateCompetitiveHistory(records)) {
    const id = clean(row.player_user_id);
    const type = clean(row.match_type).toLowerCase();
    const online = type ? type === 'online' : /^[A-Z0-9]{6}$/.test(clean(row.room_code).toUpperCase());
    if (!id || !online || typeof row.won !== 'boolean') continue;
    if (row.player_count != null && (!Number.isInteger(Number(row.player_count)) || Number(row.player_count) < 3)) continue;
    const stats = table.get(id) ?? { games: 0, wins: 0, spyWins: 0, detectiveWins: 0 };
    stats.games += 1;
    if (row.won) {
      stats.wins += 1;
      // A collective FAN answer is a team win, not evidence of catching or evading a spy.
      const scenario = clean(row.fan_scenario);
      const roleWin = !['all_spies', 'no_spies'].includes(scenario) && !['all', 'system'].includes(clean(row.winner));
      if (roleWin && clean(row.role).toLowerCase() === 'spy') stats.spyWins += 1;
      if (roleWin && clean(row.role).toLowerCase() === 'detective') stats.detectiveWins += 1;
    }
    table.set(id, stats);
  }
  return table;
}

export function achievementProgress(stats: AchievementStats = { games: 0, wins: 0, spyWins: 0, detectiveWins: 0 }): AchievementProgress[] {
  const milestone = (id: string, value: number, target: number): AchievementProgress => ({ id, progress: Math.min(count(value), target), target });
  return [
    milestone('first_mission', stats.games, 1),
    milestone('field_agent', stats.games, 10),
    milestone('veteran', stats.games, 50),
    milestone('first_victory', stats.wins, 1),
    milestone('winning_record', stats.wins, 10),
    milestone('ghost', stats.spyWins, 1),
    milestone('master_of_disguise', stats.spyWins, 10),
    milestone('sharp_eye', stats.detectiveWins, 1),
    milestone('case_closed', stats.detectiveWins, 10),
    milestone('double_agent', Math.min(stats.spyWins, stats.detectiveWins), 5),
  ];
}
