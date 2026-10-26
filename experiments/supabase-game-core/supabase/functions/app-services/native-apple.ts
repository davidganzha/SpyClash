import {AppServiceError} from './contracts.ts';
import {readCanonicalAppleSubscriptionStatus} from './billing-rules/apple-subscription-status.ts';

export const MAIN_APPLE_BUNDLE = 'com.spyclash.ios';
export const MAIN_APPLE_APP_ID = 6793534085;
export const TEST_APPLE_BUNDLE = 'com.spyclash.ios.supabasetest';
export const NATIVE_GAME_CENTER_BILLING = 'native-game-center';
const WEEKLY_PRODUCT = 'com.spyclash.ios.limitless.weekly';
type Config = Record<string,string|undefined>;
type Target = {bundle:string,environment:'Sandbox'|'Production',appAppleID?:number};

// Only the server-owned Game Center mapping selects this configuration. Keeping
// legacy billing configured globally preserves all existing account bindings.
export function nativeGameCenterConfiguration(config:Config):Config {
  return {...config,APP_BILLING_PROVIDER:NATIVE_GAME_CENTER_BILLING,SPYCLASH_LIMITLESS_ENABLED:'true'};
}
export function appleVerificationTargets(config:Config):Target[] {
  if (config.APP_IAP_ENABLED !== 'true') return [];
  if (config.APP_BILLING_PROVIDER === NATIVE_GAME_CENTER_BILLING) {
    if (config.APP_NATIVE_GAME_CENTER_IAP_ENABLED !== 'true' || config.APP_IAP_BUNDLE_ID !== MAIN_APPLE_BUNDLE
        || config.APP_IAP_APPLE_ID !== String(MAIN_APPLE_APP_ID)) return [];
    if (config.APP_IAP_ENVIRONMENT === 'SandboxAndProduction') return [
      {bundle:MAIN_APPLE_BUNDLE,environment:'Production',appAppleID:MAIN_APPLE_APP_ID},
      {bundle:MAIN_APPLE_BUNDLE,environment:'Sandbox',appAppleID:MAIN_APPLE_APP_ID},
    ];
    if (config.APP_IAP_ENVIRONMENT === 'Sandbox' || config.APP_IAP_ENVIRONMENT === 'Production')
      return [{bundle:MAIN_APPLE_BUNDLE,environment:config.APP_IAP_ENVIRONMENT,appAppleID:MAIN_APPLE_APP_ID}];
    return [];
  }
  return config.APP_IAP_BUNDLE_ID === TEST_APPLE_BUNDLE && config.APP_IAP_ENVIRONMENT === 'Sandbox'
    ? [{bundle:TEST_APPLE_BUNDLE,environment:'Sandbox'}] : [];
}
export function appleVerificationConfigured(config:Config) {
  return appleVerificationTargets(config).length > 0 && Boolean(config.APP_IAP_KEY_ID && config.APP_IAP_ISSUER_ID
    && config.APP_IAP_PRIVATE_KEY_P8 && config.APP_IAP_ROOT_CERTIFICATES_JSON);
}
async function appleTools(config:Config,target:Target) {
  const {AppStoreServerAPIClient,Environment,SignedDataVerifier,VerificationStatus} = await import('npm:@apple/app-store-server-library@3.1.0');
  const {Buffer} = await import('node:buffer');
  const roots = JSON.parse(config.APP_IAP_ROOT_CERTIFICATES_JSON!);
  if (!Array.isArray(roots) || !roots.length || roots.some(r=>typeof r !== 'string'))
    throw new AppServiceError('apple_roots_unconfigured','Apple verification roots are not configured.',503);
  const environment = target.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
  return {
    invalidEnvironment:VerificationStatus.INVALID_ENVIRONMENT,
    retryableFailure:VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
    verifier:new SignedDataVerifier(roots.map(r=>Buffer.from(r,'base64')),true,environment,target.bundle,target.appAppleID),
    client:new AppStoreServerAPIClient(config.APP_IAP_PRIVATE_KEY_P8!,config.APP_IAP_KEY_ID!,config.APP_IAP_ISSUER_ID!,target.bundle,environment),
  };
}
async function canonical(transaction:any,target:Target,tools:Awaited<ReturnType<typeof appleTools>>) {
  if (transaction.productId !== WEEKLY_PRODUCT || transaction.bundleId !== target.bundle || transaction.environment !== target.environment)
    throw new AppServiceError('transaction_identity_mismatch','The transaction belongs to a different app or product.',422);
  return await readCanonicalAppleSubscriptionStatus({transaction,expectedBundleID:target.bundle,expectedProductID:WEEKLY_PRODUCT,
    expectedEnvironment:target.environment,expectedAppAppleID:target.appAppleID || 0,
    getStatuses:id=>tools.client.getAllSubscriptionStatuses(id),
    verifyTransaction:jws=>tools.verifier.verifyAndDecodeTransaction(jws),verifyRenewal:jws=>tools.verifier.verifyAndDecodeRenewalInfo(jws)});
}
export async function verifyApple(signed:string,config:Config,dependencies?:{tools?:typeof appleTools}) {
  if (!appleVerificationConfigured(config)) throw new AppServiceError('apple_verification_unconfigured','App Store verification is not configured.',503);
  // No unverified payload field chooses the app, environment, owner or product.
  // Both environments are accepted only when explicitly enabled on the server.
  for (const target of appleVerificationTargets(config)) {
    const tools = await (dependencies?.tools || appleTools)(config,target);
    let transaction;
    try { transaction = await tools.verifier.verifyAndDecodeTransaction(signed); } catch (error:any) {
      if (error?.status === tools.invalidEnvironment) continue;
      if (error?.status === tools.retryableFailure)
        throw new AppServiceError('apple_verification_unavailable','Apple verification is temporarily unavailable. Retry the saved transaction.',503,true);
      throw new AppServiceError('invalid_apple_transaction','The App Store transaction could not be verified for this app.',422);
    }
    return await canonical(transaction,target,tools);
  }
  throw new AppServiceError('invalid_apple_transaction','The App Store transaction could not be verified for this app.',422);
}
export async function verifyStoredAppleEntitlement(record:Record<string,any>,config:Config) {
  const target = appleVerificationTargets(config).find(t=>t.environment.toLowerCase() === record.environment);
  if (!target || !appleVerificationConfigured(config)) throw new AppServiceError('apple_verification_unconfigured','App Store verification is not configured.',503);
  const tools = await appleTools(config,target);
  const info = await tools.client.getTransactionInfo(String(record.transaction_id));
  if (!info.signedTransactionInfo) throw new AppServiceError('apple_status_unavailable','App Store status is unavailable.',503,true);
  const transaction = await tools.verifier.verifyAndDecodeTransaction(info.signedTransactionInfo);
  const suppliedToken = String(transaction.appAccountToken || '').toLowerCase();
  if (transaction.originalTransactionId !== record.original_transaction_id || (suppliedToken && suppliedToken !== record.app_account_token))
    throw new AppServiceError('purchase_owner_mismatch','The verified purchase binding has changed.',409);
  // Apple may omit this optional field on renewal; the signed chain above
  // must match the binding already verified and stored by this server.
  return await canonical({...transaction,appAccountToken:record.app_account_token},target,tools);
}
