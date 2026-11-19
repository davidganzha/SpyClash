import {createClientFromRequest} from 'npm:@base44/sdk@0.8.31';
import {createMigrationExportHandler} from './envelope.mjs';
import {RECIPIENT_SPKI, EXPIRES_AT} from './recipient.ts';

// Deploy only for the approved transfer, invoke as the app administrator, then
// remove the function. It cannot return plaintext or use caller-supplied keys.
Deno.serve(createMigrationExportHandler({
  authenticate: async (request:Request) => await createClientFromRequest(request).auth.me(),
  readSecret: (name:string) => Deno.env.get(name),
  recipientSPKI:RECIPIENT_SPKI,
  expiresAt:EXPIRES_AT,
}));
