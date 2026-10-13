import {createRelayHandler} from './handler.ts';
import {sendAlertPush,sendLiveActivityPush} from './apns.ts';

Deno.serve(createRelayHandler({config:Deno.env.toObject(),send:input=>
  input.kind==='liveactivity'?sendLiveActivityPush(input):sendAlertPush(input)}));
