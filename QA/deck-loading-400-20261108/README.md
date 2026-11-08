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

## Production step — pending explicit approval

Target: production Base44 app `69a0e57fa939f578082f8091` serving spyclash.com. Operation: synchronize the exact reviewed full schema map through `PUT /api/apps/{app_id}/entity-schemas` with `{ "entityNameToSchema": candidate }`, adding only the 60 reviewed properties. This is not an App Store/TestFlight release.

Immediately before applying, refresh authentication and read the complete live schema map. Compute its digest with the preparation script's serialization and require an exact match with `before_sha256`; stop on drift. Recheck the candidate digest. After the authorized operation, read the complete map back, require the candidate digest, and verify no entities were deleted. Do not automatically retry an ambiguous mutation before readback.

After approval, validate `wordPackAction/list` and the formerly failing filters against production. If separately authorized in the same confirmation, create one disposable test room under the authenticated test account, verify its persisted revisions and loading flow, then close only that returned room ID. Existing rooms written under the old schema may lack historical metadata; the additive repair does not reconstruct already discarded fields.

At this checkpoint no production schema or data has been changed. Live loading and room acceptance remain pending the approved production step.
