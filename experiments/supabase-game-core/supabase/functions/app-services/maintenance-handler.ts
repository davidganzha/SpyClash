import { drainPushOutbox, reconcileCommittedEvents } from './worker.ts';
import { processAccountDeletionJobs } from './lifecycle.ts';

export function createMaintenanceHandler(db: any, config: Record<string,string|undefined>) {
  return async (request: Request) => {
    const secret = config.APP_WORKER_SECRET;
    const supplied = request.headers.get('x-spyclash-worker') || '';
    // This route is additionally protected by the Edge gateway JWT check.
    const hash = async (s:string) => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
    const a = await hash(secret || ''), b = await hash(supplied);
    let difference = 0; for(let i=0;i<a.length;i++) difference |= a[i]^b[i];
    if(request.method!=='POST'||!secret||secret.length<32||difference!==0) return Response.json({code:'unauthorized'},{status:401});
    try {
      const deletion = await processAccountDeletionJobs(db,config);
      if (config.APP_PUSH_DELIVERY_ENABLED==='true') await reconcileCommittedEvents(db,config);
      const push = config.APP_PUSH_DELIVERY_ENABLED==='true' ? await drainPushOutbox(db,config) : {configured:false};
      return Response.json({deletion,push},{headers:{'Cache-Control':'no-store'}});
    } catch {
      return Response.json({code:'maintenance_retry',retryable:true},{status:503});
    }
  };
}
