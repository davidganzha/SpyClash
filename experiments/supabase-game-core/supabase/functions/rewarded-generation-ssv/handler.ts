import { verifyAdMobCallback, AdMobVerificationError } from '../app-services/admob-ssv.ts';
import { AppServiceError } from '../app-services/contracts.ts';
import { rewardedAdUnit } from '../app-services/generation-reward-ledger.ts';
import { canonicalBase44Configuration, CANONICAL_BASE44_APP_ID, CANONICAL_BASE44_ORIGIN } from '../app-services/legacy-provider.ts';

type Handler = (request: Request) => Promise<Response>;
type Config = Record<string, string | undefined>;
const tokenPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(native|legacy)\.[0-9a-f]{64}$/;
const setupProbeUser = 'spyclash_admob_setup_probe';
const setupProbeData = 'spyclash_setup_probe_v1';
// Observed in the signed AdMob dashboard test on 2026-11-07; never a real ad.
const setupProbeUnit = '1234567890';
const reply = (body: unknown, status = 200) => Response.json(body, {status, headers: {'Cache-Control': 'no-store'}});

/** The only public entry point for Google's signed callback. It owns no credit
 * ledger: each backend still verifies the signature and its exact issued token.
 * Namespace is signed, server-issued data, never inferred from a user ID. */
export function createRewardedGenerationSSVGateway(dependencies: {
  config: Config; native: Handler; fetch?: typeof fetch;
}): Handler {
  const fetcher = dependencies.fetch || fetch;
  return async request => {
    if (request.method !== 'GET') return reply({code: 'method_not_allowed'}, 405);
    try {
      const event = await verifyAdMobCallback(request.url, fetcher);
      // AdMob's dashboard tests delivery with a synthetic, signed event. These
      // reserved values identify no player and can never enter either ledger.
      if (event.userID === setupProbeUser || event.customData === setupProbeData) {
        if (!rewardedAdUnit(dependencies.config)) return reply({code: 'reward_probe_unconfigured'}, 503);
        if (event.userID !== setupProbeUser || event.customData !== setupProbeData
          || event.adUnit !== setupProbeUnit
          || event.rewardAmount !== 1 || event.rewardItem !== 'generation') {
          return reply({code: 'invalid_reward_claim'}, 400);
        }
        return reply({received: true, setup_probe: true, reward_granted: false});
      }
      const namespace = tokenPattern.exec(event.customData)?.[1];
      if (!namespace || event.rewardAmount !== 1 || event.rewardItem !== 'generation') {
        return reply({code: 'invalid_reward_claim'}, 400);
      }
      if (namespace === 'native') return await dependencies.native(request);

      const destination = canonicalBase44Configuration(dependencies.config);
      if (destination.origin !== CANONICAL_BASE44_ORIGIN || destination.appID !== CANONICAL_BASE44_APP_ID) {
        return reply({code: 'reward_destination_unavailable'}, 503);
      }
      // Do not parse/rebuild parameters: order, percent escapes and literal '+'
      // belong to Google's signature. No callback data is logged or returned.
      const query = new URL(request.url).search;
      const response = await fetcher(destination.origin + '/api/apps/' + destination.appID + '/functions/generationRewardAction' + query, {
        method: 'GET', headers: {'X-App-Id': destination.appID, Origin: destination.origin, Accept: 'application/json'},
        redirect: 'error', signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) {
        await response.body?.cancel();
        return reply({code: 'reward_forward_unavailable'}, 503);
      }
      // A hosting error page with HTTP 200 is not evidence of a committed grant.
      const reader = response.body?.getReader();
      if (!reader) return reply({code: 'reward_forward_unavailable'}, 503);
      let size = 0;
      const chunks: Uint8Array[] = [];
      try {
        while (true) {
          const {done, value} = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 4_096) {
            await reader.cancel();
            return reply({code: 'reward_forward_unavailable'}, 503);
          }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      const result = JSON.parse(new TextDecoder().decode(bytes));
      if (result?.success !== true) return reply({code: 'reward_forward_unavailable'}, 503);
      return reply({received: true});
    } catch (error) {
      if (error instanceof AdMobVerificationError) return reply({code: error.code}, error.status);
      if (error instanceof AppServiceError) return reply({code: 'reward_destination_unavailable'}, 503);
      return reply({code: 'reward_callback_unavailable'}, 503);
    }
  };
}
