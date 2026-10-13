import { AppServiceError, requireUUID, type AppContext, type AppActor } from './contracts.ts';
import { digest } from './integration-crypto.ts';
import { normalizeAppleEntitlement, publicAppleEntitlement, shouldApplyProviderEvent } from './billing-rules/apple-entitlement.ts';
import { readCanonicalAppleSubscriptionStatus } from './billing-rules/apple-subscription-status.ts';
import {usesLegacyBilling,legacyBillingConfigured,prepareLegacyBilling,dispatchLegacyBilling} from './legacy-billing.ts';

export const WEEKLY_PRODUCT = 'com.spyclash.ios.limitless.weekly';
const TEST_BUNDLE = 'com.spyclash.ios.supabasetest';
const acceptedEvidence = new WeakSet<object>();
type Config = Record<string,string|undefined>;
type Preparation = {actor:AppActor,body:Record<string,any>,config:Config};

export function membershipCapabilities(config: Config) {
  if (usesLegacyBilling(config)) return {product_id:WEEKLY_PRODUCT,provider:'base44',apple_verification_configured:legacyBillingConfigured(config),
    apple_purchase_enabled:legacyBillingConfigured(config)&&config.APP_LEGACY_PURCHASES_ENABLED==='true'};
  const verification = config.APP_IAP_ENABLED === 'true' && config.APP_IAP_BUNDLE_ID === TEST_BUNDLE
    && config.APP_IAP_ENVIRONMENT === 'Sandbox' && Boolean(config.APP_IAP_KEY_ID && config.APP_IAP_ISSUER_ID
      && config.APP_IAP_PRIVATE_KEY_P8 && config.APP_IAP_ROOT_CERTIFICATES_JSON);
  return { product_id:WEEKLY_PRODUCT, apple_verification_configured:verification,
    apple_purchase_enabled:verification && config.SPYCLASH_LIMITLESS_ENABLED === 'true'
      && config.SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED === 'true' };
}

/** External verification finishes before the transaction. The opaque evidence is
 * not serializable authorization and is never accepted from the HTTP body. */
export async function prepareMembershipExternal(input: Preparation, dependencies?: { verify?: typeof verifyApple,db?:any,fetch?:typeof fetch }) {
  if (usesLegacyBilling(input.config)) {
    if (!dependencies?.db) throw new AppServiceError('legacy_billing_unconfigured','The existing billing bridge requires durable storage.',503);
    return await prepareLegacyBilling(input,{db:dependencies.db,fetch:dependencies.fetch});
  }
  if (input.body.action !== 'sync_transaction') return undefined;
  if (!membershipCapabilities(input.config).apple_verification_configured) throw new AppServiceError('apple_verification_unconfigured','App Store verification is not configured for this isolated app.',503);
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

async function verifyApple(signed: string, config: Config) {
  const { AppStoreServerAPIClient, Environment, SignedDataVerifier } = await import('npm:@apple/app-store-server-library@3.1.0');
  const { Buffer } = await import('node:buffer');
  const roots = JSON.parse(config.APP_IAP_ROOT_CERTIFICATES_JSON!);
  if (!Array.isArray(roots) || !roots.length || roots.some(r => typeof r !== 'string')) throw new AppServiceError('apple_roots_unconfigured','Apple verification roots are not configured.',503);
  const verifier = new SignedDataVerifier(roots.map(r => Buffer.from(r,'base64')),true,Environment.SANDBOX,TEST_BUNDLE,undefined);
  const transaction = await verifier.verifyAndDecodeTransaction(signed);
  if (transaction.productId !== WEEKLY_PRODUCT || transaction.bundleId !== TEST_BUNDLE || transaction.environment !== 'Sandbox') throw new AppServiceError('transaction_identity_mismatch','The transaction belongs to a different app or product.',422);
  const client = new AppStoreServerAPIClient(config.APP_IAP_PRIVATE_KEY_P8!,config.APP_IAP_KEY_ID!,config.APP_IAP_ISSUER_ID!,TEST_BUNDLE,Environment.SANDBOX);
  return await readCanonicalAppleSubscriptionStatus({transaction,expectedBundleID:TEST_BUNDLE,expectedProductID:WEEKLY_PRODUCT,
    expectedEnvironment:'Sandbox',expectedAppAppleID:0,getStatuses:id => client.getAllSubscriptionStatuses(id),
    verifyTransaction:jws => verifier.verifyAndDecodeTransaction(jws),verifyRenewal:jws => verifier.verifyAndDecodeRenewalInfo(jws)});
}

export async function dispatchMembership(ctx: AppContext, body: Record<string,any>) {
  if (usesLegacyBilling(ctx.config)) return await dispatchLegacyBilling(ctx,body);
  const action = ({check_subscription:'check',prepare_purchase:'prepare'} as Record<string,string>)[body.action] || body.action;
  if (action === 'check') return await checkMembership(ctx);
  if (action === 'prepare') {
    if ((body.requested_product_id || WEEKLY_PRODUCT) !== WEEKLY_PRODUCT) throw new AppServiceError('unsupported_product','Only the current weekly subscription is enabled.',422);
    if (!membershipCapabilities(ctx.config).apple_purchase_enabled) throw new AppServiceError('apple_purchase_unconfigured','New App Store purchases are not configured for this isolated app.',503);
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
  const {transaction,renewal,status,checkedAtMilliseconds} = evidence.verified;
  const token = requireUUID(transaction.appAccountToken,'app_account_token');
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${token+':apple-token'},0))`;
  const [owner] = await ctx.tx`select user_id,state from app_private.apple_accounts where app_account_token=${token} for update`;
  if (!owner || owner.user_id !== ctx.actor.id || owner.state !== 'active') throw new AppServiceError('purchase_owner_mismatch','This purchase is not bound to the signed-in account.',409);
  const incoming = normalizeAppleEntitlement({transaction,renewal,appleStatus:status,userID:ctx.actor.id,userEmail:ctx.actor.contactEmail,
    eventAtMilliseconds:evidence.checkedAt,now:ctx.now});
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

async function checkMembership(ctx: AppContext) {
  const unlimited = {ai_generations_daily_limit:null,premium_avatars:true,full_history:true,advanced_statistics:true,history_limit:null};
  if (ctx.config.SPYCLASH_LIMITLESS_ENABLED !== 'true') return {active:true,tier:'limitless',status:'active',protocol:'casada',providers:['casada'],benefits:unlimited,expires_at:null,ai_generations_today:null,ai_remaining:null,apple_purchase_enabled:false};
  const entitlements = await ctx.tx`select provider,expires_at from app_private.entitlements where user_id=${ctx.actor.id} and active and expires_at>${ctx.now}`;
  const grants = await ctx.tx`select expires_at from app_private.membership_grants where user_id=${ctx.actor.id} and active and (expires_at is null or expires_at>${ctx.now})`;
  const active = entitlements.length + grants.length > 0;
  const providers = [...new Set(entitlements.map((v:any)=>v.provider)),...(grants.length?['admin']:[])];
  const expiry = grants.some((v:any)=>!v.expires_at) ? null : [...entitlements,...grants].map((v:any)=>new Date(v.expires_at).toISOString()).sort().at(-1) || null;
  return {active,tier:active?'limitless':'free',status:active?'active':'inactive',protocol:'limitless',providers,
    benefits:active?unlimited:{ai_generations_daily_limit:10,premium_avatars:false,full_history:false,advanced_statistics:false,history_limit:5},
    expires_at:expiry,ai_generations_today:null,ai_remaining:null,apple_purchase_enabled:membershipCapabilities(ctx.config).apple_purchase_enabled};
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
