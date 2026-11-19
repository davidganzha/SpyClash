import {createClientFromRequest} from 'npm:@base44/sdk@0.8.31';
import {withGenerationWriterLease} from './generation-write-lifecycle.ts';
import {createRewardTransferHandler} from './handler.ts';
import {TARGETS,EXPIRES_AT} from './targets.ts';
// Temporary fixed-scope operation: deploy/invoke/read back/remove only after
// explicit approval. No caller chooses source records, account IDs or tokens.
Deno.serve(createRewardTransferHandler({targets:TARGETS,expiresAt:EXPIRES_AT,
  authenticate:async(request:Request)=>await createClientFromRequest(request).auth.me(),
  entities:(request:Request)=>createClientFromRequest(request).asServiceRole.entities,withLease:withGenerationWriterLease}));
