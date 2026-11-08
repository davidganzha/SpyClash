# Deck and lobby HTTP 400 repair — 8 November 2026

## Confirmed cause

Production Base44 app `69a0e57fa939f578082f8091` has older entity schemas than its deployed functions. Read-only requests reproduced `400 unknown_filter_field` for `WordPack.owner_user_id`, `User.spy_id`, `GameRoom.participant_user_ids`, `GameRoom.room_revision`, and `GameHistory.player_user_id`. Provider errors explicitly state that undeclared fields are also discarded on writes.

`wordPackAction/list` always queries both the stable user ID and legacy owner email. The stable-ID query fails before the successful legacy query can be returned. `communityAction` queries `User.spy_id` while resolving the profile, producing the second 400. `create_room` can succeed while undeclared room revision and membership fields are discarded; the native client then opens the room and reports the subsequent deck-load failure as a red toast.

The live read-only probe confirmed identity HTTP 200, the legacy email query HTTP 200, the stable-owner query HTTP 400, and the published `wordPackAction/list` HTTP 400. No user records or credentials are stored in this evidence.

## Prepared correction

`fields.json` allows only 60 missing properties from the checked-in schemas:

| Entity | Added fields |
| --- | ---: |
| WordPack | 1 |
| User | 14 |
| GameRoom | 34 |
| GameHistory | 11 |

`prepared/candidate.json` preserves the complete set of 28 live schemas. Only the allowlisted missing properties are added. Existing properties, validation, required fields, entity access rules, and Base44's built-in User role are preserved. New fields retain their checked-in definitions and field-level rules. No entity is removed and no record backfill is included. Other schema differences are outside this repair.

Before SHA-256: `ae0110d578658f7f17ae557619cc2414ff1a0ce9a5374ac547995cd91c7847eb`.

Candidate SHA-256: `2be448a65e564cfc67af896fcfee816c3f4aed1a47765a6d27f550b1272b8adb`.

The script `scripts/prepare-base44-schema-field-repair.py` only reads local files and prepares/checks the candidate. It has no production write operation. The repair is a schema correction; no iOS behavior or backend function is replaced. Existing app builds can benefit after it is applied. Project version metadata is synchronized to 227; marketing version remains 1.0.4.

## Validation

- 16 preparation tests passed: exact preservation, duplicate/malformed input rejection, conflict refusal, deterministic output, and read-only check mode.
- 5 actual-handler regression tests passed against checked-in handlers.
- The same 5 tests passed against freshly downloaded production handler sources, using a local SDK fixture with no network permission (`live-handler-tests.log`).
- 5 existing word-pack ownership/projection/error tests passed.
- Independent review verified that removing the 60 additions from the candidate restores the exact original snapshot.

The handler tests reproduce the original 400s and then verify successful room creation, stored revision/membership fields, deck loading, community state, and room refresh. They cover legacy email-owned decks, stable ownership precedence, foreign-deck exclusion, pagination/deduplication, empty libraries, and missing authentication. The fixture enforces the observed top-level schema query/write contract; it is not a full provider/RLS emulator or live-device acceptance test.

`handler-source-check.json` records source comparisons: the word-pack runtime matches production; community differs only by an unused monthly-purchase rollout helper, and the local room entrypoint contains a separate unpublished host-transfer addition. The second test run uses downloaded production code, avoiding those differences. No function publication is required for this repair.

## Production step — completed with explicit approval

The user approved the prepared production repair and one disposable room create/close check in this chat. Applied on 8 November 2026 at 22:23 UTC. `production-schema-receipt.json` records a fresh exact preflight match, HTTP 200 from schema synchronization, no deleted entities or warnings, and exact candidate readback across all 28 schemas. The provider lists all synchronized entities as updated; semantic comparison confirms only the reviewed four schema definitions changed.

`production-runtime-receipt.json` confirms all five formerly failing field filters now return HTTP 200. The published word-pack list and community state returned HTTP 200 before and after room creation. Exactly one test room was created successfully; its membership IDs, room/lobby revisions and write token persisted. Room refresh returned HTTP 200. Closing the test room succeeded on the first request, and a separate exact-ID entity lookup confirmed the room was removed.

The authenticated account returned an empty deck library (zero owned packs), not a loading error. The existing signed-in app on **SpyClash Theme Ideas QA**, build **1.0.4 (225)**, was also checked: tapping the existing Retry button replaced the old red 400 panel with `onlineRoom.noSavedWordPacks` / “Вы не создавали своих колод.” See `simulator-after-retry.json` and `simulator-after-retry.jpg`. No new app build or installation was needed. The pre-existing room visible in that Simulator was not the disposable API test room and was left untouched.

The production test created and closed a waiting room; it did not start a multiplayer match or claim physical-device acceptance.

Target: production Base44 app `69a0e57fa939f578082f8091` serving spyclash.com. Operation: synchronize the exact reviewed full schema map through `PUT /api/apps/{app_id}/entity-schemas` with `{ "entityNameToSchema": candidate }`, adding only the 60 reviewed properties. This is not an App Store/TestFlight release.

Immediately before applying, refresh authentication and read the complete live schema map. Compute its digest with the preparation script's serialization and require an exact match with `before_sha256`; stop on drift. Recheck the candidate digest. After the authorized operation, read the complete map back, require the candidate digest, and verify no entities were deleted. Do not automatically retry an ambiguous mutation before readback.

The approved validation used `wordPackAction/list` and the formerly failing filters, then one disposable test room under the authenticated account, with persisted revisions and lobby loading checked before closing only its returned ID. Existing rooms written under the old schema may lack historical metadata; the additive repair does not reconstruct already discarded fields.

Production schema repair, live endpoint validation, test-room cleanup, and the existing Simulator's deck-load recovery are complete. Credentials and user/deck contents are not included in these receipts.
