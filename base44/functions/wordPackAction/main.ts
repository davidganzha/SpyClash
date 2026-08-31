import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  assertBillingWriterLease,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import {
  cleanWordPackValue,
  ownsWordPack,
  uniqueWordPacks,
  wordPackForClient,
  type WordPackRecord,
  wordPackWritePayload,
} from "./word-pack.ts";
import {
  canonicalBase44Request,
  canonicalIdentityClientConfig,
  hasTrustedBase44Context,
} from "./base44-context.ts";
import { withWordPackWriterLease } from "./word-pack-write-lifecycle.ts";

const PAGE_SIZE = 100;
const MAX_PACKS = 500;

function jsonError(error: unknown, status = 400, code?: string) {
  const message = error instanceof Error
    ? error.message
    : String(error || "Request failed");
  return Response.json({ error: message, ...(code ? { code } : {}) }, {
    status,
  });
}

async function allMatching(
  store: any,
  filter: Record<string, unknown>,
): Promise<WordPackRecord[]> {
  const output: WordPackRecord[] = [];
  for (let skip = 0; output.length < MAX_PACKS; skip += PAGE_SIZE) {
    const page: WordPackRecord[] = await store.filter(
      filter,
      "-created_date",
      PAGE_SIZE,
      skip,
    ) || [];
    output.push(...page);
    if (page.length < PAGE_SIZE) break;
  }
  return output.slice(0, MAX_PACKS);
}

async function ownedPacks(store: any, user: WordPackRecord) {
  const userID = cleanWordPackValue(user.id);
  const email = cleanWordPackValue(user.email);
  const [stableRows, legacyRows] = await Promise.all([
    allMatching(store, { owner_user_id: userID }),
    allMatching(store, { owner_email: email }),
  ]);
  return uniqueWordPacks([...stableRows, ...legacyRows])
    .filter((record) => ownsWordPack(record, user));
}

async function exactPack(store: any, id: string) {
  if (!id) return null;
  const rows: WordPackRecord[] =
    await store.filter({ id }, "created_date", 2, 0) || [];
  if (rows.length > 1) {
    throw Object.assign(new Error("Word pack identity is ambiguous."), {
      status: 409,
      code: "ambiguous_word_pack",
    });
  }
  return rows[0] || null;
}

function lifecycleStatus(error: BillingIdentityLifecycleError) {
  return ["deletion_in_progress", "active_lease", "cas_contention"].includes(
      error.code,
    )
    ? 409
    : 503;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonError("Method not allowed", 405);
    }
    if (!hasTrustedBase44Context(req)) {
      return jsonError("Unauthorized", 401);
    }
    const body: WordPackRecord = await req.json().catch(() => ({}));
    const accessToken = cleanWordPackValue(body.access_token);
    if (!accessToken) return jsonError("Unauthorized", 401);

    const identityClient = createClient(
      canonicalIdentityClientConfig(accessToken),
    );
    const user: WordPackRecord = await identityClient.auth.me();
    if (!cleanWordPackValue(user?.id) || !cleanWordPackValue(user?.email)) {
      return jsonError("Unauthorized", 401);
    }

    const base44 = createClientFromRequest(canonicalBase44Request(req));
    const store = base44.asServiceRole.entities.WordPack;
    const lifecycleStore =
      base44.asServiceRole.entities.BillingIdentityLifecycle;
    const action = cleanWordPackValue(body.action).toLowerCase();

    if (action === "list") {
      const packs = await ownedPacks(store, user);
      return Response.json(
        packs.map(wordPackForClient).sort((left, right) =>
          left.name.localeCompare(right.name, undefined, {
            sensitivity: "base",
          })
        ),
      );
    }

    const userID = cleanWordPackValue(user.id);
    if (action === "create") {
      const payload = wordPackWritePayload(body, user);
      const created = await withWordPackWriterLease({
        lifecycleStore,
        userID,
        action: async (lease) => {
          await assertBillingWriterLease(lifecycleStore, lease);
          return await store.create(payload);
        },
      });
      return Response.json(wordPackForClient(created));
    }

    if (!["update", "delete"].includes(action)) {
      return jsonError(`Unsupported action: ${action || "missing"}`, 400);
    }

    const packID = cleanWordPackValue(body.pack_id || body.id);
    if (!packID) return jsonError("Word pack id is required.", 400);

    return await withWordPackWriterLease({
      lifecycleStore,
      userID,
      action: async (lease) => {
        const existing = await exactPack(store, packID);
        if (!existing) return jsonError("Word pack not found.", 404);
        if (!ownsWordPack(existing, user)) return jsonError("Forbidden", 403);

        if (action === "delete") {
          await assertBillingWriterLease(lifecycleStore, lease);
          await store.delete(packID);
          return Response.json({ success: true });
        }

        const payload = wordPackWritePayload(body, user);
        await assertBillingWriterLease(lifecycleStore, lease);
        const updated = await store.update(packID, payload);
        return Response.json(wordPackForClient(updated));
      },
    });
  } catch (error) {
    console.error("wordPackAction error", error);
    if (error instanceof BillingIdentityLifecycleError) {
      return jsonError(error, lifecycleStatus(error), error.code);
    }
    const status = Number((error as { status?: unknown })?.status) || 500;
    const code = cleanWordPackValue((error as { code?: unknown })?.code) ||
      undefined;
    return jsonError(error, status, code);
  }
});
