# Notification inbox contract

The server exposes one exact, bounded inbox window per authenticated user:

- the newest 500 retained global announcements;
- the newest 500 retained committed personal projections;
- each scope is capped independently, so global news cannot evict invitations;
- both scopes retain the existing 90-day time boundary and expiry rules;
- ordering is `published_at DESC, id ASC`;
- list pagination and unread totals are derived from the same bounded snapshot.

Items older than the 500-item scope window are outside the product inbox even
when they remain in server-owned history. An opaque list cursor cannot continue
beyond that window. A new item may move the oldest item out of the live window,
which is the intended rolling-window behavior.

Read receipts remain server-only. Receipt queries are batched by exact item key
and have a fixed duplicate-cardinality guard. If the server-only uniqueness
invariant is violated, notification actions fail closed with
`receipt_cardinality_exceeded` instead of returning an approximate unread total.

This contract bounds each request to at most 500 source items per scope and a
fixed number of keyed receipt batches. It never scans every row retained during
the 90-day history window.
