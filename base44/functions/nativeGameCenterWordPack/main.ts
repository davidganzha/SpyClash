import {createClientFromRequest} from 'npm:@base44/sdk@0.8.31';
import {createNativeWordPackRelay} from './handler.ts';

Deno.serve(createNativeWordPackRelay({secret:Deno.env.get('SPYCLASH_NATIVE_AI_RELAY_SECRET')||'',
  gatewayToken:Deno.env.get('SPYCLASH_NATIVE_AI_RELAY_ANON_KEY')||'',
  diagnose:(event)=>console.warn('native_ai_relay_failure',JSON.stringify(event)),
  invoke:(request,input)=>createClientFromRequest(request).asServiceRole.integrations.Core.InvokeLLM(input),
}));
