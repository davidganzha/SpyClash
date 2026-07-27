import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  boundedText,
  clean,
  type Entity,
  NotificationContractError,
} from "./contracts.ts";
import {
  adminItem,
  createDraft,
  inboxUnreadCounts,
  publishDraft,
  publishGlobal,
  queryInboxPage,
  requireScope,
  upsertReceipt,
  validateItemOwnership,
  withdrawAnnouncement,
} from "./inbox.ts";
import { withNotificationWriteLease } from "./receipt-lifecycle.ts";
import { withSerializedAdminMutation } from "./admin-publish-lifecycle.ts";

const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";

async function authenticatedUser(req: Request, body: Entity): Promise<Entity> {
  const accessToken = clean(body.access_token);
  const appID = clean(req.headers.get("Base44-App-Id"));
  const serviceHeader = clean(
    req.headers.get("Base44-Service-Authorization"),
  );
  if (
    !accessToken || appID !== SPYCLASH_BASE44_APP_ID ||
    !serviceHeader.startsWith("Bearer ")
  ) {
    throw new NotificationContractError("Unauthorized", 401, "unauthorized");
  }
  const identityClient = createClient({
    appId: SPYCLASH_BASE44_APP_ID,
    serverUrl: "https://base44.app",
    token: accessToken,
  });
  const user = await identityClient.auth.me();
  if (!user?.id) {
    throw new NotificationContractError("Unauthorized", 401, "unauthorized");
  }
  return user;
}

function errorResponse(error: unknown): Response {
  if (error instanceof NotificationContractError) {
    return Response.json({ error: error.message, code: error.code }, {
      status: error.status,
    });
  }
  console.error(
    "notificationAction failed",
    error instanceof Error ? error.message : error,
  );
  return Response.json(
    { error: "Notifications are temporarily unavailable." },
    {
      status: 500,
    },
  );
}

function requireAdmin(user: Entity): void {
  if (clean(user.role) !== "admin") {
    throw new NotificationContractError("Forbidden", 403, "forbidden");
  }
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return Response.json({ error: "Method not allowed" }, { status: 405 });
    }
    const body = await req.json().catch(() => ({})) as Entity;
    const action = clean(body.action).toLowerCase();
    const base44 = createClientFromRequest(req);
    const user = await authenticatedUser(req, body);
    const userID = clean(user.id);
    const locale = boundedText(body.locale || user.language, 32) || "en";
    const announcementStore =
      base44.asServiceRole.entities.NotificationAnnouncement;
    const receiptStore = base44.asServiceRole.entities.NotificationReadReceipt;
    const lifecycleStore =
      base44.asServiceRole.entities.BillingIdentityLifecycle;

    if (action === "summary") {
      return Response.json({
        ok: true,
        unread: await inboxUnreadCounts({ base44, userID, locale }),
        server_time: new Date().toISOString(),
      });
    }

    if (action === "list") {
      const scope = requireScope(body.scope);
      const page = await queryInboxPage({
        base44,
        userID,
        locale,
        scope,
        limit: body.limit,
        cursor: body.cursor,
      });
      return Response.json({
        ok: true,
        scope,
        items: page.items,
        unread: page.unread,
        next_cursor: page.next_cursor,
      });
    }

    if (action === "mark_read") {
      const itemID = boundedText(body.item_id, 260);
      if (!/^(global|personal):[^:]{1,220}$/.test(itemID)) {
        throw new NotificationContractError("item_id is invalid.");
      }
      let ownedItem = await validateItemOwnership({
        base44,
        userID,
        itemID,
        locale,
      });
      const readAt = new Date().toISOString();
      await withNotificationWriteLease({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userID,
        action: async (persist) => {
          // Revalidate after obtaining the account-deletion opposing lease.
          ownedItem = await validateItemOwnership({
            base44,
            userID,
            itemID,
            locale,
          });
          await upsertReceipt({
            store: receiptStore,
            userID,
            key: itemID,
            readAt,
            persist,
          });
        },
      });
      return Response.json({
        ok: true,
        item: { ...ownedItem, read_at: readAt },
        unread: await inboxUnreadCounts({ base44, userID, locale }),
      });
    }

    if (action === "mark_all_read") {
      const scope = requireScope(body.scope);
      const readAt = new Date().toISOString();
      const key = scope === "all" ? "__all__" : `__all__:${scope}`;
      await withNotificationWriteLease({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userID,
        action: async (persist) => {
          await upsertReceipt({
            store: receiptStore,
            userID,
            key,
            readAt,
            persist,
          });
        },
      });
      return Response.json({
        ok: true,
        unread: await inboxUnreadCounts({ base44, userID, locale }),
      });
    }

    requireAdmin(user);

    if (action === "publish_global") {
      const requestID = clean(body.request_id) || crypto.randomUUID();
      const saved = await withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: userID,
        operationKey: `request:${requestID}`,
        action: async (persist) =>
          await publishGlobal({
            store: announcementStore,
            body: { ...body, request_id: requestID },
            persist,
          }),
      });
      return Response.json({
        ok: true,
        item: adminItem(saved, locale),
        unread: await inboxUnreadCounts({ base44, userID, locale }),
        request_id: clean(saved.dedupe_key).replace(/^notification:/, ""),
        revision: saved.fanout_revision,
      });
    }

    if (action === "create_draft") {
      const requestID = clean(body.request_id) || crypto.randomUUID();
      const saved = await withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: userID,
        operationKey: `request:${requestID}`,
        action: async (persist) =>
          await createDraft({
            store: announcementStore,
            body: { ...body, request_id: requestID },
            persist,
          }),
      });
      return Response.json({
        ok: true,
        announcement_id: saved.id,
        status: saved.status,
        revision: saved.fanout_revision,
      });
    }

    if (action === "publish") {
      const announcementID = clean(body.announcement_id);
      const saved = await withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: userID,
        operationKey: `announcement:${announcementID}`,
        action: async (persist) =>
          await publishDraft({
            store: announcementStore,
            announcementID,
            expectedRevision: body.expected_revision,
            persist,
          }),
      });
      return Response.json({
        ok: true,
        item: adminItem(saved, locale),
        unread: await inboxUnreadCounts({ base44, userID, locale }),
        revision: saved.fanout_revision,
      });
    }

    if (action === "withdraw") {
      const announcementID = clean(body.announcement_id);
      const saved = await withSerializedAdminMutation({
        lifecycleStore,
        adminUserID: userID,
        operationKey: `announcement:${announcementID}`,
        action: async (persist) =>
          await withdrawAnnouncement({
            announcementStore,
            pushEventStore: base44.asServiceRole.entities.PushNotificationEvent,
            announcementID,
            expectedRevision: body.expected_revision,
            persist,
          }),
      });
      return Response.json({
        ok: true,
        announcement_id: saved.id,
        status: saved.status,
        revision: saved.fanout_revision,
      });
    }

    throw new NotificationContractError(
      "Unsupported notification action.",
      400,
      "unsupported_action",
    );
  } catch (error) {
    return errorResponse(error);
  }
});
