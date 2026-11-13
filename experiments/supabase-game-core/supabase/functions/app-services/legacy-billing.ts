import {AppServiceError, requireUUID, type AppActor, type AppContext} from './contracts.ts';
import {canonical, digest} from './integration-crypto.ts';
import {assertIsolatedSupabase, canonicalBase44Configuration, verifyLegacyCredential, boundedLegacyJSON, CANONICAL_BASE44_APP_ID, CANONICAL_BASE44_ORIGIN} from './legacy-provider.ts';
import type {AppleLoyaltySnapshot} from './billing-rules/apple-loyalty.ts';
import {WEEKLY_PRODUCT,MONTHLY_PRODUCT,APPLE_SUBSCRIPTION_PRODUCTS,isAppleSubscriptionProduct,monthlyAppleCheckoutEnabled} from './billing-rules/apple-products.ts';

type Config = Record<string,string|undefined>;
const evidenceSet = new WeakSet<object>();
const WEEKLY = WEEKLY_PRODUCT;
// Fixed canonical route: the original name currently serves an obsolete
// Stripe-only contract. Never accept an endpoint from client input or fall back
// to that response when the verified membership route is unavailable.
const MEMBERSHIP_FUNCTION = 'checkSubscriptionV2';
// Monthly checkout has a separate gate. Restore may reconcile either product, but
// Base44 must verify its signature, canonical status and immutable owner first.
const RESTORABLE_PRODUCTS: ReadonlySet<string> = new Set(APPLE_SUBSCRIPTION_PRODUCTS);
const actions = new Set(['check','prepare','sync_transaction']);
export function usesLegacyBilling(config:Config) { return config.APP_BILLING_PROVIDER === 'base44'; }
export function legacyBillingConfigured(config:Config) {
  if (!usesLegacyBilling(config) || config.APP_LEGACY_BILLING_ENABLED !== 'true') return false;
  try {
    assertIsolatedSupabase(config);
    const destination = canonicalBase44Configuration(config);
    return destination.origin === CANONICAL_BASE44_ORIGIN && destination.appID === CANONICAL_BASE44_APP_ID;
  } catch { return false; }
}
function request(body:Record<string,any>) {
  const action = ({check_subscription:'check',prepare_purchase:'prepare'} as Record<string,string>)[body.action] || body.action;
  if (!actions.has(action)) throw new AppServiceError('invalid_action','Unknown membership action.');
  if (action === 'check') return {action};
  requireUUID(body.request_id,'request_id');
  if (action === 'prepare') {
    const productID = body.requested_product_id === undefined ? WEEKLY : body.requested_product_id;
    if (!isAppleSubscriptionProduct(productID)) throw new AppServiceError('unsupported_product','Unsupported App Store subscription product.',422);
    return {action,requested_product_id:productID};
  }
  if (typeof body.signed_transaction !== 'string' || body.signed_transaction.length < 20 || body.signed_transaction.length > 250_000) throw new AppServiceError('invalid_transaction','A signed Apple transaction is required.');
  return {action,signed_transaction:body.signed_transaction};
}
async function requireLinked(tx:any, actor:AppActor, legacyID:string, origin:string) {
  await tx`select pg_advisory_xact_lock_shared(hashtextextended(${'spyclash-account:'+actor.id},0))`;
  const [profile] = await tx`select state from app_private.profiles where user_id=${actor.id}`;
  const [link] = await tx`select * from app_private.legacy_links where user_id=${actor.id}`;
  if (profile?.state !== 'active') throw new AppServiceError('account_unavailable','This account is unavailable.',410);
  if (!link || link.state !== 'active' || link.legacy_user_id !== legacyID || link.source_origin !== origin) throw new AppServiceError('legacy_owner_mismatch','Sign in to the linked Base44 account.',409);
}
function membershipResponse(value:any) {
  if (!value || typeof value.active !== 'boolean' || !['free','limitless'].includes(value.tier) || !['casada','limitless'].includes(value.protocol)
    || !Array.isArray(value.providers) || value.providers.some((v:any)=>typeof v !== 'string') || !value.benefits || typeof value.benefits.premium_avatars !== 'boolean') {
    throw new AppServiceError('legacy_billing_response_invalid','The existing membership could not be verified.',502,true);
  }
  if (value.expires_at != null && !Number.isFinite(Date.parse(value.expires_at))) throw new AppServiceError('legacy_billing_response_invalid','The existing membership expiry is invalid.',502,true);
  return value;
}

function verifiedLoyaltySnapshot(value:any, now:Date): AppleLoyaltySnapshot | undefined {
  const validID = (id:unknown): id is string => typeof id === 'string' && /^[0-9]{1,128}$/.test(id);
  const checked = typeof value?.verified_at === 'string' ? Date.parse(value.verified_at) : NaN;
  if (!value || value.environment !== 'production' || !validID(value.original_transaction_id)
    || !Number.isFinite(checked) || checked < 0 || checked > now.getTime()+300_000
    || !Array.isArray(value.transaction_ids) || value.transaction_ids.length > 2000
    || !value.transaction_ids.every(validID)) return undefined;
  return {original_transaction_id:value.original_transaction_id,environment:'production',
    transaction_ids:[...new Set<string>(value.transaction_ids)],verified_at:new Date(checked).toISOString()};
}

/** Input is server-only Base44 evidence. Never pass the client request here.
 * New complete histories replace a chain, so refunds can remove paid periods;
 * ordinary membership checks, outages and delayed restores retain prior data. */
export function mergeLegacyLoyaltyChains(previous:unknown, incoming:unknown, now:Date) {
  const chains:Record<string,AppleLoyaltySnapshot> = {};
  if (previous && typeof previous === 'object' && !Array.isArray(previous)) {
    for (const [key,value] of Object.entries(previous)) {
      const snapshot = verifiedLoyaltySnapshot(value,now);
      if (snapshot?.original_transaction_id === key) chains[key] = snapshot;
    }
  }
  const next = verifiedLoyaltySnapshot(incoming,now);
  if (next && (!chains[next.original_transaction_id]
    || Date.parse(next.verified_at) >= Date.parse(chains[next.original_transaction_id].verified_at))) {
    chains[next.original_transaction_id] = next;
  }
  return chains;
}

/** Existing Base44 is the commerce authority. Its credential and verified user
 * ID are distinct from the Supabase actor; neither email nor client JSON links
 * accounts. No Apple key, Stripe key, or client JWS trust is introduced here. */
export async function prepareLegacyBilling(input:{actor:AppActor,body:Record<string,any>,config:Config}, dependencies:{db:any,fetch?:typeof fetch}) {
  if (!legacyBillingConfigured(input.config)) throw new AppServiceError('legacy_billing_unconfigured','The existing billing bridge is not enabled.',503);
  const command = request(input.body);
  if (command.action === 'prepare' && input.config.APP_LEGACY_PURCHASES_ENABLED !== 'true') throw new AppServiceError('apple_purchase_unconfigured','Purchases have not been enabled for this candidate.',503);
  if (command.action === 'prepare' && command.requested_product_id === MONTHLY_PRODUCT && !monthlyAppleCheckoutEnabled(input.config))
    throw new AppServiceError('apple_monthly_purchase_unconfigured','Monthly App Store purchases are not enabled.',503);
  const fetcher = dependencies.fetch || fetch;
  const verified = await verifyLegacyCredential(input.config,input.body.base44_access_token,fetcher);
  const hash = await digest(canonical({service:'membership',...command}));
  const requestID = command.action === 'check' ? null : input.body.request_id;
  const previous = await dependencies.db.begin(async(tx:any)=>{
    await requireLinked(tx,input.actor,verified.identity.id,verified.origin);
    if (!requestID) return undefined;
    await tx`select pg_advisory_xact_lock(hashtextextended(${input.actor.id+':legacy:'+requestID},0))`;
    const [prior] = await tx`select * from app_private.legacy_operations where user_id=${input.actor.id} and request_id=${requestID} for update`;
    if (prior && (prior.request_hash !== hash || prior.legacy_user_id !== verified.identity.id)) throw new AppServiceError('request_id_reused','This request belongs to another operation.',409);
    if (!prior) await tx`insert into app_private.legacy_operations(user_id,request_id,request_hash,legacy_user_id) values(${input.actor.id},${requestID},${hash},${verified.identity.id})`;
    return prior?.state === 'complete' ? prior.response : undefined;
  });
  const invoke = async(name:string,body:any) => {
    let response:Response;
    try { response = await fetcher(verified.origin+'/api/apps/'+verified.appID+'/functions/'+name,{method:'POST',redirect:'error',
      headers:{Authorization:'Bearer '+verified.credential,'X-App-Id':verified.appID,Origin:verified.origin,'Content-Type':'application/json'},
      body:JSON.stringify({...body,access_token:verified.credential}),signal:AbortSignal.timeout(25_000)}); }
    catch { throw new AppServiceError('legacy_billing_unavailable','The existing billing service is temporarily unavailable. Retry the saved request.',503,true); }
    const value = await boundedLegacyJSON(response);
    // Preserve only the provider's explicit, temporary account-lease signal.
    // Native retries the same saved JWS; arbitrary backend codes/messages must
    // not become retry authorization or diagnostic identifiers.
    if (!response.ok && name === 'app-store-entitlement' && command.action === 'sync_transaction'
      && response.status === 503 && value?.code === 'apple_account_binding_busy' && value?.retryable === true) {
      throw new AppServiceError('apple_account_binding_busy','Apple account binding is being updated. Retry shortly.',503,true);
    }
    if (!response.ok) throw new AppServiceError('legacy_billing_rejected',typeof value?.error === 'string' ? value.error.slice(0,300) : 'The existing billing service could not confirm this action.',response.status,response.status >= 500 || response.status === 429);
    return value;
  };
  let result:any, snapshot:any;
  if (previous) ({result,snapshot}=previous);
  else if (command.action === 'check') result = snapshot = membershipResponse(await invoke(MEMBERSHIP_FUNCTION,{}));
  else {
    result = await invoke('app-store-entitlement',command);
    if (command.action === 'prepare') {
      if (result?.product_id !== command.requested_product_id) throw new AppServiceError('legacy_billing_response_invalid','The prepared product does not match the requested subscription.',502);
      requireUUID(result.app_account_token,'app_account_token');
    } else {
      if (result?.success !== true || result?.server_status_verified !== true
        || !RESTORABLE_PRODUCTS.has(result?.entitlement?.product_id)
        || (result?.submitted_product_id != null && !RESTORABLE_PRODUCTS.has(result.submitted_product_id))) {
        throw new AppServiceError('legacy_billing_response_invalid','Apple has not verified a supported subscription transaction.',502,true);
      }
      snapshot = membershipResponse(await invoke(MEMBERSHIP_FUNCTION,{}));
    }
  }
  const snapshotCheckedAt = previous ? Number(previous.snapshotCheckedAt) || 0 : Date.now();
  const evidence = {actor:input.actor.id,legacyID:verified.identity.id,origin:verified.origin,action:command.action,requestID,hash,result,snapshot,snapshotCheckedAt,checkedAt:Date.now()};
  evidenceSet.add(evidence);return evidence;
}

export async function dispatchLegacyBilling(ctx:AppContext,body:Record<string,any>) {
  const command = request(body), evidence = ctx.evidence;
  if (!evidence || !evidenceSet.has(evidence) || evidence.actor !== ctx.actor.id || evidence.action !== command.action
    || Date.now()-evidence.checkedAt > 90_000 || evidence.hash !== await digest(canonical({service:'membership',...command}))) throw new AppServiceError('legacy_billing_verification_required','A fresh verified billing response is required.',401);
  await requireLinked(ctx.tx,ctx.actor,evidence.legacyID,evidence.origin);
  if (evidence.snapshot) {
    const snapshot = evidence.snapshot;
    // A short server-only cache grants no indefinite stale provider access. All
    // refreshes are performed with the current linked Base44 credential.
    const expiry = new Date(Math.min(evidence.snapshotCheckedAt+300_000,snapshot.expires_at ? Date.parse(snapshot.expires_at) : Infinity));
    const active = snapshot.active === true && expiry > ctx.now;
    const checkedAt = new Date(evidence.snapshotCheckedAt);
    const sourceKey = 'base44:'+evidence.legacyID;
    // Serialize empty-row inserts as well as subsequent mirror refreshes. This
    // prevents a simultaneous aggregate check from erasing a verified chain.
    await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${sourceKey},0))`;
    const [owner] = await ctx.tx`select user_id,data from app_private.entitlements where source_key=${sourceKey} for update`;
    if (owner && owner.user_id !== ctx.actor.id) throw new AppServiceError('legacy_owner_mismatch','This membership belongs to a different account.',409);
    const loyaltyChains = mergeLegacyLoyaltyChains(owner?.data?.loyalty_chains,
      command.action === 'sync_transaction' && evidence.result?.entitlement?.environment === 'production'
        ? evidence.result?.loyalty : undefined,ctx.now);
    const data = {status:active?'active':'inactive',providers:snapshot.providers,protocol:snapshot.protocol,source_expires_at:snapshot.expires_at,verified_at:checkedAt.toISOString(),
      ...(Object.keys(loyaltyChains).length ? {loyalty_chains:loyaltyChains} : {})};
    // A membership read aggregates Apple, Stripe and grants; it must not relabel
    // a previously verified monthly transaction as the current weekly offer.
    const productID = command.action === 'sync_transaction' ? evidence.result.entitlement.product_id : '';
    await ctx.tx`insert into app_private.entitlements(source_key,user_id,active,expires_at,data,provider,product_id,provider_event_at,updated_at)
      values(${'base44:'+evidence.legacyID},${ctx.actor.id},${active},${expiry},${ctx.tx.json(data)},'base44',${productID},${checkedAt},${ctx.now})
      on conflict(source_key) do update set active=excluded.active,expires_at=excluded.expires_at,data=excluded.data,
        product_id=case when excluded.product_id<>'' then excluded.product_id else entitlements.product_id end,
        provider_event_at=excluded.provider_event_at,updated_at=excluded.updated_at
      where entitlements.user_id=excluded.user_id and (entitlements.provider_event_at is null or entitlements.provider_event_at<=excluded.provider_event_at)`;
  }
  if (evidence.requestID) {
    const rows = await ctx.tx`update app_private.legacy_operations set state='complete',response=${ctx.tx.json({result:evidence.result,snapshot:evidence.snapshot||null,snapshotCheckedAt:evidence.snapshotCheckedAt})}
      where user_id=${ctx.actor.id} and request_id=${evidence.requestID} and request_hash=${evidence.hash} returning request_id`;
    if (!rows.length) throw new AppServiceError('legacy_billing_reservation_missing','Retry the original billing request.',409);
  }
  return command.action === 'check' ? {...evidence.result,apple_purchase_enabled:evidence.result.apple_purchase_enabled === true && ctx.config.APP_LEGACY_PURCHASES_ENABLED === 'true'} : evidence.result;
}
