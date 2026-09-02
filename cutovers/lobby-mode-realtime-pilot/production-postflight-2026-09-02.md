# Production postflight: lobby mode realtime pilot

Date: `2026-09-02`

## Authorized production scope

- Canonical Base44 app: `69a0e57fa939f578082f8091`.
- Authorized schema operation: `entities push`, with the only intended semantic
  change in `GameRoomSignal`.
- Authorized function operation: targeted
  `functions deploy gameRoomAction`.
- No other production mutation was authorized or performed as part of this
  cutover.

## Sealed source

- Source stage: `20260902T114206Z-f779cb7a2593`.
- Original manifest SHA-256:
  `b505693697b2a64d209ac2cbb9da3098d5e7cd20122e76f1a7eddffff7e39596`.

## Entity postflight

- Remote inventory after the schema push: `24/24` entities.
- Created entities: `0`.
- Deleted entities: `0`.
- Independent semantic comparison against the sealed preflight found exactly
  one changed entity: `GameRoomSignal`.
- The remote `GameRoomSignal` schema matched the sealed candidate.

## Function deployment and pullback

The first targeted function command was rejected locally before upload. The
pulled package used a nested Base44 export layout, so its configured entry point
was not present at the deploy package root:

```text
Entry point 'base44/functions/gameRoomAction/entry.ts' not found in files
```

No function mutation occurred during that failed attempt. A deterministic flat
deploy bridge was then constructed from the sealed candidate:

- `43/43` runtime files were copied byte-for-byte from the sealed nested tree;
- the only package metadata normalization changed the entry path to `entry.ts`;
- no additional runtime file or function was included.

A fresh read-only prefunction pull confirmed the full `17/17` function baseline
before retry. The targeted `gameRoomAction` deployment then succeeded.

Post-deploy pullback evidence:

- `gameRoomAction` pulled tree SHA-256:
  `604776d49063a86841465c9361e7d9866bbf137a1502972cebc164c267b1401a`;
- this hash matched the sealed candidate projection;
- all `16` non-target functions remained unchanged;
- `pushNotificationAction` remained unchanged at SHA-256
  `034b0a521086950fa5f7dc00109eb6e238e5f40a5cf9b08140808cee5a0581d4`.

A phase-aware read-only `candidate-postflight` verification subsequently
completed with `POSTFLIGHT_VERIFIED`, confirming the candidate schema, target
function, all 16 non-target function hashes, and the 24-entity inventory.

## Derived v2 rollback package

The original sealed v1 stage and manifest were left byte-for-byte unchanged.
A separate local derived-v2 stage was built from its exact pre-cutover snapshot
to correct only the Base44 deploy layout and preserve explicit provenance:

- derived stage: `20260902T114206Z-f779cb7a2593-derived-v2`;
- parent manifest SHA-256:
  `b505693697b2a64d209ac2cbb9da3098d5e7cd20122e76f1a7eddffff7e39596`;
- derived manifest SHA-256:
  `0dd21e0919bd4f97945bd9ef50f5e68410a2dc0498b0b2100f07e0177f5e96c5`;
- candidate flat deploy tree SHA-256:
  `d3ab984fe018e2d63bd64e1a770f012dd7ba8ed2d6a9b74a22e00edfa41e67dc`;
- rollback flat deploy tree SHA-256:
  `d5b2ce0d33ba4d1fd2039e30022e6d8499db4329092b9e038f7ff3e117edf575`;
- expected rollback pull-back tree SHA-256:
  `d8a8e7f9080618de4b1f248a534c6a094bae3de2d9021b588381f4ed377d11d0`.

Both deploy directories contain exactly `44` root files (`function.jsonc` plus
`43` runtime files) and no nested directories. Rollback remains derived from
the pre-cutover baseline; no production rollback was executed.

## Result and remaining acceptance

The authorized production state is structurally converged. No rollback trigger
was observed, and rollback was not performed.

Runtime behavior and latency remain unverified. Acceptance still requires two
physical iPhones on client build `126` or later, two different authenticated
accounts, and a newly created waiting room. The host must switch
`Вопросы ↔ Ассоциации` while the second device records propagation latency and
confirms the direct realtime path. Deployment and structural pullback alone do
not establish that the latency target has been met.
