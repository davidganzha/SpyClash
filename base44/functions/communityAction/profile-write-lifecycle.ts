import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";

type Persist = <T>(writer: () => Promise<T>) => Promise<T>;
type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

/** Initializes the current profile inside the action's existing lease set. */
export async function withCurrentProfileWriteLease<T>(input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  currentUserID: unknown;
  loadCurrent: () => Promise<Entity | null>;
  ensureCurrent: (current: Entity, persist: Persist) => Promise<Entity>;
  installCurrent: (current: Entity) => void;
  action: (guard: { persist: Persist }) => Promise<T>;
}): Promise<T> {
  const protectedUserIDs = new Set(input.userIDs.map(clean).filter(Boolean));
  const currentUserID = clean(input.currentUserID);
  return await withCommunityWriteLeases({
    lifecycleStore: input.lifecycleStore,
    userIDs: input.userIDs,
    action: async (guard) => {
      if (protectedUserIDs.has(currentUserID)) {
        const current = await input.loadCurrent();
        if (!current) {
          throw Object.assign(new Error("Operative not found"), {
            status: 404,
          });
        }
        input.installCurrent(await input.ensureCurrent(current, guard.persist));
      }
      return await input.action(guard);
    },
  });
}
