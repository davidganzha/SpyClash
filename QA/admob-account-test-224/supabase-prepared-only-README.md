# Native test-offer preparation — not deployed

Fresh live app-services v19 (JWT enabled) matched all 72 source files from the prior deployment receipt. This candidate changes only generation-reward-ledger.ts and generation-rewards.ts. The existing public SSV gateway needs no update.

SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS is a comma-separated exact allowlist of authenticated native account IDs. With global SPYCLASH_REWARDED_GENERATION_ENABLED=false, only a matched account receives test_ad_available and its actual unused bonus balance. Its normal enabled/ad_available remain false, and free_remaining remains null. Test preparation accepts existing free access, bonus balance and LIMITLESS; normal generation quotas, membership, provider flow and credit spending are unchanged. Other accounts keep their previous response shape and do not read reward balances while disabled. No request-body ID, email, wildcard or client metadata can confer access.

Google's real signature and issued token still grant exactly one real ledger credit. No client-side crediting was added. Revoking the test allowlist blocks new offers but allows already-issued signed callbacks to settle. A received test credit stays stored; normal global-off generation does not spend it.

Validation against this exact live-derived candidate: 23 isolated local PostgreSQL integration checks passed (18 previous + 5 test-offer cases); entrypoint and test script typechecks passed. All provider/Google responses were fixtures. No production requests, grants, schema changes, deployment or secrets changes were performed. The test account is not yet identified in this package; do not activate a guessed ID.

The current normal Debug client uses Base44, so this native candidate can remain undeployed for the planned test. See RUNTIME-SHA256.json and LIVE-TO-CANDIDATE.diff for the exact optional future publication delta. Root owns final version/commit and any explicitly approved deployment.
