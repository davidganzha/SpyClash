import { AppServiceError } from './contracts.ts';
import {
  selectSharedWordPackStock,
  type SharedWordPackRequest,
  type SharedWordPackVariant,
} from './word-generation/shared-word-pack-library.ts';

/** The database handle is server-owned. None of these functions grants clients
 * direct access to the shared library or accepts an actor ID from the client. */
export function createSharedWordPackSQLStore(db: any) {
  const unavailable = () => new AppServiceError(
    'shared_library_unavailable',
    'Word library is temporarily unavailable. Retry this request.',
    503,
    true,
  );
  return {
    async read(request: SharedWordPackRequest) {
      try {
        const [row] = await db`select public.word_pack_library_read(${request.cacheKey}) as records`;
        if (!row || !Array.isArray(row.records)) throw unavailable();
        return await selectSharedWordPackStock({ request, records: row.records });
      } catch { throw unavailable(); }
    },
    async claim(cacheKey: string, token: string): Promise<boolean> {
      try {
        const [row] = await db`select public.word_pack_library_claim(${cacheKey}, ${token}::uuid) as claimed`;
        if (typeof row?.claimed !== 'boolean') throw unavailable();
        return row.claimed;
      } catch { throw unavailable(); }
    },
    async publish(record: SharedWordPackVariant, token: string): Promise<boolean> {
      try {
        const [row] = await db`select public.word_pack_library_publish(${db.json(record)}::jsonb, ${token}::uuid) as published`;
        if (typeof row?.published !== 'boolean') throw unavailable();
        return row.published;
      } catch { throw unavailable(); }
    },
    async release(cacheKey: string, token: string): Promise<void> {
      try {
        await db`select public.word_pack_library_release(${cacheKey}, ${token}::uuid)`;
      } catch { throw unavailable(); }
    },
  };
}
