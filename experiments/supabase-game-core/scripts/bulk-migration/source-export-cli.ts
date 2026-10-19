// From repository root, pipe this file to authenticated `npx base44 exec` with
// --app-id 69a0e57fa939f578082f8091 and BASE44_APP_ID set to the same value.
// Redirect stdout/stderr to private ignored files; never print the raw archive.
// Set BULK_MIGRATION_CAPTURE=fresh-<unique-name> to capture independently below
// .local/bulk-migration without replacing the original sealed snapshot.
declare const base44: Parameters<typeof import('./source-export.ts').runSourceExport>[0];
const { runSourceExport, ExportError } = await import('file://' + Deno.cwd() + '/experiments/supabase-game-core/scripts/bulk-migration/source-export.ts');
// SDK errors may log provider response bodies. Only bounded, sanitized results
// may leave this process; the archival file is the sole full-data destination.
const originalError = console.error, originalWarn = console.warn;
console.error = () => {};
console.warn = () => {};
try {
  await runSourceExport(base44, Deno.cwd(), Deno.env.get('BULK_MIGRATION_CAPTURE'));
} catch (error) {
  const safe = error instanceof ExportError ? error as { code: string; entity?: string } : undefined;
  console.log(JSON.stringify({ exported: false, code: safe?.code || 'export_failed', entity: safe?.entity }));
  Deno.exit(1);
} finally {
  console.error = originalError;
  console.warn = originalWarn;
}
