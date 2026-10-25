// Immutable test deployment identity. This artifact must never run on the live project.
export const experimentalProjectReference = 'ovowoixuyabccgkxcexp';
export function cloudEnvironment(environment) {
  if (environment.SUPABASE_URL !== 'https://' + experimentalProjectReference + '.supabase.co' ||
      (environment.GAME_CENTER_PROJECT_REF && environment.GAME_CENTER_PROJECT_REF !== experimentalProjectReference) ||
      (environment.GAME_CENTER_ENVIRONMENT && environment.GAME_CENTER_ENVIRONMENT !== 'experimental-000')) {
    throw new Error('This artifact only runs on the pinned Game Center test project.');
  }
  return {...environment, GAME_CENTER_ENVIRONMENT:'experimental-000', GAME_CENTER_PROJECT_REF:experimentalProjectReference};
}
