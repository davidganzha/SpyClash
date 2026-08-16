import { boundedText, clean } from "./contracts.ts";
import {
  alertPayload,
  type PushEvent,
  type SourceContext,
} from "./push-events.ts";
import { safePushActorName } from "./public-name-safety.ts";

export const PERSONAL_INBOX_EVENT_TYPES = [
  "friend_request",
  "room_invite",
] as const;

export function isPersonalInboxEvent(event: PushEvent): boolean {
  return (PERSONAL_INBOX_EVENT_TYPES as readonly string[]).includes(
    clean(event.event_type),
  );
}

function alertCopy(
  event: PushEvent,
  source: SourceContext,
  locale: "en" | "ru" | "es" | "uk",
) {
  const payload = alertPayload(event, {
    ...source,
    actorName: safePushActorName(source.actorName),
  }, locale);
  const aps = payload.aps as Record<string, unknown>;
  const alert = aps.alert as Record<string, unknown>;
  return {
    title: boundedText(alert?.title, 80),
    body: boundedText(alert?.body, 800),
    deepLink: boundedText(payload.deep_link, 500),
  };
}

export function committedPersonalInboxPatch(
  event: PushEvent,
  source: SourceContext,
  now = new Date(),
): PushEvent {
  const en = alertCopy(event, source, "en");
  const ru = alertCopy(event, source, "ru");
  const es = alertCopy(event, source, "es");
  const uk = alertCopy(event, source, "uk");
  return {
    inbox_kind: clean(event.event_type),
    inbox_importance: "important",
    inbox_title_en: en.title,
    inbox_body_en: en.body,
    inbox_title_ru: ru.title,
    inbox_body_ru: ru.body,
    inbox_title_es: es.title,
    inbox_body_es: es.body,
    inbox_title_uk: uk.title,
    inbox_body_uk: uk.body,
    inbox_action_deep_link: en.deepLink.startsWith("spyclash://")
      ? en.deepLink
      : "spyclash://notifications",
    inbox_published_at: clean(
      event.inbox_published_at || event.created_at || event.created_date,
    ) || now.toISOString(),
    inbox_projection_version: 1,
    inbox_visible: true,
    inbox_committed_at: now.toISOString(),
    updated_at: now.toISOString(),
  };
}

export function hiddenPersonalInboxPatch(now = new Date()): PushEvent {
  return {
    inbox_projection_version: 1,
    inbox_visible: false,
    inbox_committed_at: now.toISOString(),
    updated_at: now.toISOString(),
  };
}
