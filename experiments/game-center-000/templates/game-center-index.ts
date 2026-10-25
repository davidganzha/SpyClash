import {cloudEnvironment} from './backend/cloud-configuration.mjs';
import {ensureProfile} from '../app-services/profile.ts';
import {createExperimentalRuntime} from './backend/runtime.mjs';
const runtime=createExperimentalRuntime(cloudEnvironment(Deno.env.toObject()),ensureProfile);
Deno.serve(runtime.handler);
