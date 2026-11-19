import {AppServiceError,requireUUID} from './contracts.ts';
/** Callback routing is selected only by an imported, source-fenced exact
 * capability. A header or a client-supplied UUID can never create this row. */
export async function hasImportedRewardAlias(db:any,customData:string) {
  const [schema]=await db`select to_regclass('apple_private.reward_attempt_aliases') is not null as present`;
  if(!schema.present)return false;
  const rows=await db`select 1 from apple_private.reward_attempt_aliases where custom_data=${customData}`;
  return rows.length===1;
}
export async function importedRewardOwner(tx:any,event:{customData:string;userID:string},unity:boolean) {
  const [alias]=await tx`select r.user_id,r.attempt_id,r.legacy_user_id,a.legacy_user_id as owner_legacy_id
    from apple_private.reward_attempt_aliases r join apple_private.accounts a on a.user_id=r.user_id
    where r.custom_data=${event.customData}`;
  if(!alias||alias.legacy_user_id!==alias.owner_legacy_id||(!unity&&event.userID!==alias.legacy_user_id)||alias.attempt_id!==event.customData.split('.')[0])
    throw new AppServiceError('invalid_reward_claim','The transferred reward did not match its original owner.',400);
  return {user_id:requireUUID(alias.user_id,'user_id')};
}
