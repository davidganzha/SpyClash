// Run only through the already-authenticated Base44 CLI with the canonical app ID.
// Redirect stdout to a private ignored file; never print/export user content to chat.
declare const base44:any;
if(Deno.env.get('BASE44_APP_ID')!=='69a0e57fa939f578082f8091')throw new Error('Unexpected source app.');
const {captureLegacySocialExport}=await import('file://'+Deno.cwd()+'/supabase/functions/app-services/legacy-social.ts');
try {
  const snapshot=await captureLegacySocialExport((entity:any,options:any)=>base44.entities[entity].list(options.sort,options.limit,options.skip,options.fields));
  console.log('SPYCLASH_SOCIAL_EXPORT '+JSON.stringify(snapshot));
} catch(error) {
  console.error(JSON.stringify({export_failed:true,code:error instanceof Error?error.name:'source_error'}));
  Deno.exit(1);
}
