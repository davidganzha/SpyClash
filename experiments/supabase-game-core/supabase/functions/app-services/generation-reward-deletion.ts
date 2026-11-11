/** Run within the account deletion transaction, after the profile tombstone.
 * Optional-table checks preserve deletion before the advertising migrations.
 * The account gate prevents enrollment/credit writers from reopening access. */
export async function eraseGenerationRewardAccountData(tx: any, userID: string) {
  const [schema] = await tx`select
    to_regclass('game_center_private.generation_reward_attempts') is not null as attempts,
    to_regclass('game_center_private.generation_reward_enrollments') is not null as enrollments`;
  if (schema.attempts) {
    await tx`delete from game_center_private.generation_reward_attempts where user_id=${userID}`;
  }
  if (schema.enrollments) {
    await tx`delete from game_center_private.generation_reward_enrollments where user_id=${userID}`;
  }
}
