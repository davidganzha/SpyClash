import assert from 'node:assert/strict';
import { aggregateAchievementStats, aggregateLoyaltyPayments, achievementProgress } from '../../supabase/functions/app-services/policies/achievements.ts';
import { projectedProfiles } from '../../supabase/functions/app-services/profile.ts';
import type { AppContext } from '../../supabase/functions/app-services/contracts.ts';

const row = (match: string, extra: Record<string, unknown> = {}) => ({
  match_id: match, player_user_id: 'agent-a', match_type: 'online', room_code: 'ABC234',
  won: true, role: 'spy', player_count: 4, ...extra,
});
Deno.test('awards count completed multiplayer once, including multi-spy and FAN missions', () => {
  const first = row('first');
  const rows = [first, { ...first, id: 'duplicate' }, row('multi', { spy_count: 2, ranked: false }),
    row('fan', { fan_mode_enabled: true, fan_scenario: 'no_spies', role: 'detective', winner: 'all', ranked: false })];
  assert.deepEqual(aggregateAchievementStats(rows).get('agent-a'), { games: 3, wins: 3, spyWins: 2, detectiveWins: 0 });
});
Deno.test('local, malformed, unfinished, email-only and too-small matches cannot unlock awards', () => {
  const invalid = [row('local', { match_type: 'local' }), row('unfinished', { won: undefined }),
    row('string-result', { won: 'true' }), row('email-only', { player_user_id: '', player_email: 'a@example.test' }),
    row('small', { player_count: 2 }), row('bad-count', { player_count: 'invalid' })];
  assert.equal(aggregateAchievementStats(invalid).size, 0);
});
Deno.test('legacy online history is retained and identities are isolated', () => {
  const rows = [row('legacy', { match_type: undefined }), row('other', { player_user_id: 'agent-b', role: 'detective' }),
    row('bad-legacy', { match_type: undefined, room_code: 'LOCAL' })];
  const stats = aggregateAchievementStats(rows);
  assert.deepEqual(stats.get('agent-a'), { games: 1, wins: 1, spyWins: 1, detectiveWins: 0 });
  assert.deepEqual(stats.get('agent-b'), { games: 1, wins: 1, spyWins: 0, detectiveWins: 1 });
});
Deno.test('FAN group wins never unlock role awards; standard FAN role wins do', () => {
  const rows = [row('all', { fan_scenario: 'all_spies', winner: 'all' }),
    row('none', { fan_scenario: 'no_spies', role: 'detective', winner: 'all' }),
    row('incorrect', { fan_scenario: 'all_spies', winner: 'system', won: false }),
    row('standard', { fan_mode_enabled: true, fan_scenario: 'standard', winner: 'spy', ranked: false })];
  assert.deepEqual(aggregateAchievementStats(rows).get('agent-a'), { games: 4, wins: 3, spyWins: 1, detectiveWins: 0 });
});
Deno.test('award thresholds remain bounded; double-agent requires wins on both sides', () => {
  const awards = achievementProgress({ games: 500, wins: 80, spyWins: 9, detectiveWins: 4 });
  assert.equal(awards.length, 13);
  assert.deepEqual(awards.find(a => a.id === 'veteran'), { id: 'veteran', progress: 50, target: 50 });
  assert.deepEqual(awards.find(a => a.id === 'master_of_disguise'), { id: 'master_of_disguise', progress: 9, target: 10 });
  assert.deepEqual(awards.find(a => a.id === 'double_agent'), { id: 'double_agent', progress: 4, target: 5 });
  assert.ok(achievementProgress({ games: -3, wins: NaN, spyWins: Infinity, detectiveWins: -1 }).every(a => a.progress === 0));
});

Deno.test('Loyalty uses distinct verified production payments across billing snapshots, never membership access', () => {
  const verified_at = '2026-11-05T10:00:00Z';
  const rows = [
    {user_id:'a',provider:'apple',active:false,data:{environment:'production',loyalty_transaction_ids:['100','101','101'],loyalty_verified_at:verified_at}},
    {user_id:'a',provider:'base44',data:{loyalty_chains:{'99':{environment:'production',transaction_ids:['100','102'],verified_at}}}},
    {user_id:'a',provider:'apple',active:true,data:{environment:'sandbox',loyalty_transaction_ids:['103'],loyalty_verified_at:verified_at}},
    {user_id:'a',provider:'admin',data:{environment:'production',loyalty_transaction_ids:['104'],loyalty_verified_at:verified_at}},
    {user_id:'a',provider:'apple',active:true,data:{environment:'production',loyalty_transaction_ids:['105']}},
    {user_id:'b',provider:'apple',data:{environment:'production',loyalty_transaction_ids:['200','bad-id',null,300],loyalty_verified_at:verified_at}},
  ];
  assert.deepEqual([...aggregateLoyaltyPayments(rows)], [['a',3],['b',1]]);
  assert.deepEqual(achievementProgress(undefined, 6).filter(a=>a.id.startsWith('loyalty_')), [
    {id:'loyalty_3',progress:3,target:3},{id:'loyalty_6',progress:6,target:6},{id:'loyalty_12',progress:6,target:12},
  ]);
});

Deno.test('public Loyalty projection exposes only bounded awards and ignores forged profile billing', async () => {
  const tx = async (parts: TemplateStringsArray) => parts.join('').includes('app_private.entitlements')
    ? [{user_id:'agent-a',provider:'apple',data:{environment:'production',loyalty_transaction_ids:['900','901','902'],loyalty_verified_at:'2026-11-05T10:00:00Z'}}] : [];
  const [profile] = await projectedProfiles({tx} as unknown as AppContext, [{user_id:'agent-a',spy_id:'123-456',data:{
    display_name:'Agent',loyalty_transaction_ids:['forged'],paidSubscriptions:999,
    achievements:[{id:'loyalty_12',progress:12,target:12}],
  }}]);
  assert.deepEqual(profile.achievements.find((a:any)=>a.id==='loyalty_3'),{id:'loyalty_3',progress:3,target:3});
  assert.deepEqual(profile.achievements.find((a:any)=>a.id==='loyalty_12'),{id:'loyalty_12',progress:3,target:12});
  assert.ok(!JSON.stringify(profile).includes('900'));
  assert.ok(!JSON.stringify(profile).includes('loyalty_transaction_ids'));
});
Deno.test('public projection ignores writable profile counters and forged awards', async () => {
  const ctx = { tx: async () => [{ result: row('real', { won: false }) }] } as unknown as AppContext;
  const [profile] = await projectedProfiles(ctx, [{ user_id: 'agent-a', spy_id: '123-456', data: {
    display_name: 'Agent', games_played: 9999, games_won: 9999,
    achievements: [{ id: 'veteran', progress: 50, target: 50 }],
  } }]);
  assert.deepEqual(profile.achievements.find((a: any) => a.id === 'first_mission'), { id: 'first_mission', progress: 1, target: 1 });
  assert.deepEqual(profile.achievements.find((a: any) => a.id === 'veteran'), { id: 'veteran', progress: 1, target: 50 });
  assert.deepEqual(profile.achievements.find((a: any) => a.id === 'first_victory'), { id: 'first_victory', progress: 0, target: 1 });
  assert.ok(!JSON.stringify(profile.achievements).includes('player_email'));
});
