import {AppServiceError} from './contracts.ts';
import {nativeGameCenterAccount,nativeGameCenterHasMembership} from './native-game-center.ts';

/** Only private, imported ownership can select native services. Legacy links
 * remain provenance for migrated Apple users; editable Auth metadata is ignored.
 * Caller holds the shared/exclusive spyclash-account lock. */
export async function nativeAccount(tx:any,userID:string) {
  const [schema]=await tx`select to_regclass('app_private.native_accounts') is not null as present`;
  if(!schema.present) {
    const account=await nativeGameCenterAccount(tx,userID);
    return account ? {...account,provider:'game_center',migration_complete:true} : undefined;
  }
  const [registered]=await tx`select * from app_private.native_accounts where user_id=${userID}`;
  if(!registered) {
    // Existing deployments and fixtures retain their original GC ownership check.
    const account=await nativeGameCenterAccount(tx,userID);
    return account ? {...account,provider:'game_center',migration_complete:true} : undefined;
  }
  if(registered.provider==='game_center') {
    const account=await nativeGameCenterAccount(tx,userID);
    if(!account||account.identity_key!==registered.identity_key)throw conflict();
    return {...account,provider:'game_center',migration_complete:true};
  }
  const [account]=await tx`select identity_key,user_id,state,legacy_user_id,migration_complete,migration_version
    from apple_private.accounts where user_id=${userID}`;
  if(!account||account.identity_key!==registered.identity_key||account.state!==registered.state
      ||account.migration_complete!==registered.migration_complete)throw conflict();
  const legacy=await tx`select legacy_user_id from app_private.legacy_links where user_id=${userID}
    union all select legacy_user_id from app_private.legacy_session_accounts where user_id=${userID}`;
  if(legacy.some((row:any)=>row.legacy_user_id!==account.legacy_user_id))throw conflict();
  if(account.state==='pending'||!account.migration_complete||account.migration_version<1)
    throw new AppServiceError('apple_migration_pending','Your saved account is still being transferred. Try again later.',503,true);
  return {...account,provider:'apple'};
}
const conflict=()=>new AppServiceError('native_identity_conflict','Account ownership needs to be verified before continuing.',409);

export async function resolveNativeAccount(db:any,userID:string) {
  return await db.begin(async(tx:any)=>{
    await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+userID},0))`;
    return await nativeAccount(tx,userID);
  });
}
export const nativeHasMembership=nativeGameCenterHasMembership;
