import { AppServiceError, requireUUID, type AppContext, type AppActor } from './contracts.ts';
import { digest } from './integration-crypto.ts';
import { normalizeAppleEntitlement, publicAppleEntitlement, shouldApplyProviderEvent } from './billing-rules/apple-entitlement.ts';
import {appleVerificationConfigured,verifyApple,verifyStoredAppleEntitlement,nativeGameCenterConfiguration,NATIVE_GAME_CENTER_BILLING} from './native-apple.ts';
import {nativeGameCenterAccount,resolveNativeGameCenterAccount} from './native-game-center.ts';
import {accountGate} from './account-gate.ts';
import {usesLegacyBilling,legacyBillingConfigured,prepareLegacyBilling,dispatchLegacyBilling} from './legacy-billing.ts';

export const WEEKLY_PRODUCT = 'com.spyclash.ios.limitless.weekly';
const acceptedEvidence = new WeakSet<object>();
type Config = Record<string,string|undefined>;
type Preparation = {actor:AppActor,body:Record<string,any>,config:Config};

export function membershipCapabilities(config: Config) {
  if (usesLegacyBilling(config)) return {product_id:WEEKLY_PRODUCT,provider:'base44',apple_verification_configured:legacyBillingConfigured(config),
    apple_purchase_enabled:legacyBillingConfigured(config)&&config.APP_LEGACY_PURCHASES_ENABLED==='true'};
  const verification = appleVerificationConfigured(config);
  return { product_id:WEEKLY_PRODUCT, apple_verification_configured:verification,
    apple_purchase_enabled:verification && config.SPYCLASH_LIMITLESS_ENABLED === 'true'
      && config.SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED === 'true' };
}

/** External verification finishes before the transaction. The opaque evidence is
 * not serializable authorization and is never accepted from the HTTP body. */
export async function prepareMembershipExternal(input: Preparation, dependencies?: { verify?: typeof verifyApple,db?:any,fetch?:typeof fetch }) {
  if (dependencies?.db && await resolveNativeGameCenterAccount(dependencies.db,input.actor.id))
    input = {...input,config:nativeGameCenterConfiguration(input.config)};
  if (usesLegacyBilling(input.config)) {
    if (!dependencies?.db) throw new AppServiceError('legacy_billing_unconfigured','The existing billing bridge requires durable storage.',503);
    return await prepareLegacyBilling(input,{db:dependencies.db,fetch:dependencies.fetch});
  }
  if (input.body.action !== 'sync_transaction') return undefined;
  if (!membershipCapabilities(input.config).apple_verification_configured) throw new AppServiceError('apple_verification_unconfigured','App Store verification is not configured for this account.',503);
  const signed = input.body.signed_transaction;
  if (typeof signed !== 'string' || signed.length < 20 || signed.length > 250_000) throw new AppServiceError('invalid_transaction','A signed Apple transaction is required.');
  const checkedAt = Date.now();
  let verified;
  try { verified = await (dependencies?.verify || verifyApple)(signed,input.config); }
  catch (error) {
    if (error instanceof AppServiceError) throw error;
    throw new AppServiceError('apple_verification_failed','The App Store transaction could not be verified.',503,true);
  }
  const evidence = { actor:input.actor.id, bodyHash:await digest(signed), checkedAt, verified };
  acceptedEvidence.add(evidence);
  return evidence;
}

export async function dispatchMembership(ctx: AppContext, body: Record<string,any>) {
  if (usesLegacyBilling(ctx.config) || ctx.config.APP_BILLING_PROVIDER === NATIVE_GAME_CENTER_BILLING) {
    const native = await nativeGameCenterAccount(ctx.tx,ctx.actor.id);
    if (native?.state === 'deleted') throw new AppServiceError('account_unavailable','This account has been deleted.',403);
    if (native) ctx = {...ctx,config:nativeGameCenterConfiguration(ctx.config)};
    else if (usesLegacyBilling(ctx.config)) return await dispatchLegacyBilling(ctx,body);
    else throw new AppServiceError('game_center_identity_required','A verified Game Center account is required.',403);
  }
  const action = ({check_subscription:'check',prepare_purchase:'prepare'} as Record<string,string>)[body.action] || body.action;
  if (action === 'check') return await checkMembership(ctx);
  if (action === 'prepare') {
    if ((body.requested_product_id || WEEKLY_PRODUCT) !== WEEKLY_PRODUCT) throw new AppServiceError('unsupported_product','Only the current weekly subscription is enabled.',422);
    if (!membershipCapabilities(ctx.config).apple_purchase_enabled) throw new AppServiceError('apple_purchase_unconfigured','New App Store purchases are not configured for this account.',503);
    const membership = await checkMembership(ctx);
    if (membership.active) throw new AppServiceError('membership_already_active','This account already has access.',409);
    await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${ctx.actor.id+':apple-account'},0))`;
    await ctx.tx`insert into app_private.apple_accounts(user_id,app_account_token) values(${ctx.actor.id},${crypto.randomUUID()}) on conflict(user_id) do nothing`;
    const [account] = await ctx.tx`select * from app_private.apple_accounts where user_id=${ctx.actor.id} for update`;
    if (account.state !== 'active') throw new AppServiceError('account_deleted','This billing identity is unavailable.',409);
    return {product_id:WEEKLY_PRODUCT,app_account_token:account.app_account_token};
  }
  if (action !== 'sync_transaction') throw new AppServiceError('invalid_action','Unknown membership action.');
  const evidence = ctx.evidence;
  if (!evidence || !acceptedEvidence.has(evidence) || evidence.actor !== ctx.actor.id || evidence.bodyHash !== await digest(String(body.signed_transaction || ''))
      || Date.now()-evidence.checkedAt > 60_000) throw new AppServiceError('verified_transaction_required','A fresh server-verified transaction is required.',422);
  return await applyVerifiedMembership(ctx,evidence.verified,evidence.checkedAt);
}

async function applyVerifiedMembership(ctx:AppContext,verified:any,checkedAt:number) {
  const {transaction,renewal,status} = verified;
  const token = requireUUID(transaction.appAccountToken,'app_account_token');
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${token+':apple-token'},0))`;
  const [owner] = await ctx.tx`select user_id,state from app_private.apple_accounts where app_account_token=${token} for update`;
  if (!owner || owner.user_id !== ctx.actor.id || owner.state !== 'active') throw new AppServiceError('purchase_owner_mismatch','This purchase is not bound to the signed-in account.',409);
  const incoming = normalizeAppleEntitlement({transaction,renewal,appleStatus:status,userID:ctx.actor.id,userEmail:ctx.actor.contactEmail,
    eventAtMilliseconds:checkedAt,now:ctx.now});
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${incoming.source_key+':entitlement'},0))`;
  const [prior] = await ctx.tx`select user_id,data from app_private.entitlements where source_key=${incoming.source_key} for update`;
  if (prior && prior.user_id !== ctx.actor.id) throw new AppServiceError('purchase_owner_mismatch','This subscription belongs to another account.',409);
  const record = prior && !shouldApplyProviderEvent(prior.data,incoming) ? prior.data : incoming;
  const active = ['active','trialing','grace_period'].includes(record.status) && Date.parse(record.expires_at)>ctx.now.getTime();
  await ctx.tx`insert into app_private.entitlements(source_key,user_id,active,expires_at,data,provider,product_id,provider_event_at,updated_at)
    values(${record.source_key},${ctx.actor.id},${active},${record.expires_at},${ctx.tx.json(record)},'apple',${record.product_id},${record.provider_event_at},${ctx.now})
    on conflict(source_key) do update set active=excluded.active,expires_at=excluded.expires_at,data=excluded.data,provider_event_at=excluded.provider_event_at,updated_at=excluded.updated_at`;
  return {success:true,server_status_verified:true,submitted_product_id:WEEKLY_PRODUCT,entitlement:publicAppleEntitlement(record)};
}

export async function checkMembership(ctx: AppContext) {
  const unlimited = {ai_generations_daily_limit:null,premium_avatars:true,full_history:true,advanced_statistics:true,history_limit:null};
  if (ctx.config.SPYCLASH_LIMITLESS_ENABLED !== 'true') return {active:true,tier:'limitless',status:'active',protocol:'casada',providers:['casada'],benefits:unlimited,expires_at:null,ai_generations_today:null,ai_remaining:null,apple_purchase_enabled:false};
  const entitlements = await ctx.tx`select provider,expires_at from app_private.entitlements where user_id=${ctx.actor.id} and active and expires_at>${ctx.now}`;
  const grants = await ctx.tx`select expires_at from app_private.membership_grants where user_id=${ctx.actor.id} and active and (expires_at is null or expires_at>${ctx.now})`;
  const active = entitlements.length + grants.length > 0;
  const providers = [...new Set(entitlements.map((v:any)=>v.provider)),...(grants.length?['admin']:[])];
  const expiry = grants.some((v:any)=>!v.expires_at) ? null : [...entitlements,...grants].map((v:any)=>new Date(v.expires_at).toISOString()).sort().at(-1) || null;
  const native = ctx.config.APP_BILLING_PROVIDER === NATIVE_GAME_CENTER_BILLING;
  const [usage] = native ? await ctx.tx`select count(*)::integer as total from game_center_private.generation_requests where user_id=${ctx.actor.id} and usage_date=(${ctx.now}::timestamptz at time zone 'UTC')::date and charged` : [];
  const used = native ? Number(usage?.total || 0) : null;
  return {active,tier:active?'limitless':'free',status:active?'active':'inactive',protocol:'limitless',providers,
    benefits:active?unlimited:{ai_generations_daily_limit:10,premium_avatars:false,full_history:false,advanced_statistics:false,history_limit:5},
    expires_at:expiry,ai_generations_today:used,ai_remaining:active || used === null ? null : Math.max(0,10-used),apple_purchase_enabled:membershipCapabilities(ctx.config).apple_purchase_enabled};
}

/** Called inside the account deletion transaction. Billing ownership is retained
 * as a tombstone so a later account cannot claim the same purchase. */
export async function cleanupBillingPush(ctx: AppContext) {
  await ctx.tx`update app_private.apple_accounts set state='deleted' where user_id=${ctx.actor.id}`;
  await ctx.tx`update app_private.entitlements set active=false,data=data-'user_email' where user_id=${ctx.actor.id}`;
  await ctx.tx`delete from app_private.membership_grants where user_id=${ctx.actor.id}`;
  await ctx.tx`delete from app_private.push_registrations where user_id=${ctx.actor.id}`;
  await ctx.tx`update app_private.legacy_links set state='deleted' where user_id=${ctx.actor.id}`;
  await ctx.tx`delete from app_private.legacy_operations where user_id=${ctx.actor.id}`;
  // This bridge stores no provider credentials. Root owns Supabase auth deletion
  // and must enqueue revocation only if future migration imports such credentials.
}

/** Reconcile an owned subscription before consuming its benefits. Existing
 * Base44 webhooks remain untouched. The canonical Apple API catches renewal,
 * refund and revocation even when no new device transaction arrives. */
export async function refreshNativeMembership(input:Preparation,dependencies:{db:any,verify?:typeof verifyStoredAppleEntitlement}) {
  const native = await resolveNativeGameCenterAccount(dependencies.db,input.actor.id);
  if (!native) return input.config;
  if (native.state !== 'ready') throw new AppServiceError('account_unavailable','This account is unavailable.',403);
  const config = nativeGameCenterConfiguration(input.config);
  const consumes = input.body.service === 'membership' && ['check','check_subscription','prepare','prepare_purchase'].includes(input.body.action)
    || input.body.service === 'legacy' && ['generate','generate_word_pack'].includes(input.body.action)
    || input.body.service === 'profile' && ['update','update_profile'].includes(input.body.action)
      && ['avatar','spy_card_theme','spy_card_accent','spy_card_badge'].some(field=>input.body[field] !== undefined)
    || input.body.service === 'game' && input.body.action === 'get_history';
  if (!consumes) return config;
  const rows = await dependencies.db.begin(async(tx:any)=>{
    await accountGate(tx,input.actor.id);
    return await tx`select data from app_private.entitlements where user_id=${input.actor.id} and provider='apple'`;
  });
  for (const row of rows) {
    const age = Date.now()-Date.parse(row.data.last_verified_at || '');
    if (age >= 0 && age < 60_000) continue;
    const checkedAt = Date.now();
    let verified;
    try { verified = await (dependencies.verify || verifyStoredAppleEntitlement)(row.data,config); }
    catch (error) {
      if (error instanceof AppServiceError) throw error;
      throw new AppServiceError('apple_status_unavailable','Your subscription could not be checked. Try again shortly.',503,true);
    }
    await dependencies.db.begin(async(tx:any)=>{
      await accountGate(tx,input.actor.id);
      const current = await nativeGameCenterAccount(tx,input.actor.id);
      if (current?.state !== 'ready') throw new AppServiceError('account_unavailable','This account is unavailable.',403);
      await applyVerifiedMembership({tx,actor:input.actor,config,now:new Date()},verified,checkedAt);
    });
  }
  return config;
}
