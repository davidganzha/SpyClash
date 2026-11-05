type Handler = (request: Request) => Promise<Response>;

/** Shared by the deployed entry point and HTTP integration tests. Relay routes
 * use their signed service protocol; they must never enter user-token auth. */
export function createAppRouter(handlers: {app: Handler; maintenance: Handler; nativeAIRelay: Handler; generationRewardSSV?:Handler}): Handler {
  return request => {
    const path = new URL(request.url).pathname;
    if(path.endsWith('/rewarded-generation/ssv'))return handlers.generationRewardSSV
      ?handlers.generationRewardSSV(request):Promise.resolve(Response.json({code:'reward_unavailable'},{status:503}));
    if (['claim', 'complete', 'fail'].some(action => path.endsWith('/native-ai-relay/' + action))) {
      return handlers.nativeAIRelay(request);
    }
    return path.endsWith('/maintenance') ? handlers.maintenance(request) : handlers.app(request);
  };
}
