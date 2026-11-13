# Independent profile and invitation dependency review

Reviewed the local App Services candidate assembled from the downloaded v26
baseline. No network mutations or production actions were performed.

The prepared Loyalty projection requires more than the billing snapshot write.
`profile.ts` computes awards from private match history and server-verified
production billing snapshots; `policies/achievements.ts` deduplicates and bounds
that progress; `policies/community.ts` includes only the resulting award list in
the public profile. Profile-input counters and fabricated awards are overwritten.
Apple transaction IDs, account tokens, history snapshots and billing fields are
not included in the public result.

The prepared invitation controls require the profile preference update,
`policies/invitation-permissions.ts`, and matching checks in `community.ts`,
`inbox.ts` and `worker.ts`. Friend invitations retain their existing default;
stranger invitations require explicit opt-in, and relationship blocks override
both. Sending, listing and accepting recheck the recipient's policy. Nonfriend
sends have the prepared cooldown/rate limit. Queued push delivery rechecks the
live invitation, participant, waiting room and recipient policy, so an opt-out
does not leave an already-queued invitation eligible for delivery.

Compared the candidate's six profile/community/policy/inbox files against the
intended source and inspected the seventh file, `worker.ts`, against the exact
local baseline. Its patch contains only the event type selection and queued
invitation recheck. Existing push transport, topic selection and relay behavior
remain unchanged in this candidate; separate source-only main-app push relay
tests cannot be treated as validation of that unchanged transport.

Validation against imports redirected to the exact candidate:

- `profile-policy-tests.log`: 11 Deno tests passed, zero failed. Includes private
  billing projection, forged counters, FAN group wins, malformed history,
  invitation defaults, block overrides and strict settings input.
- `profile-services-tests.tap`: 19 local database integration tests passed,
  zero failed/skipped. Includes friend/stranger consent, wrong-recipient
  rejection, duplicate invitations, revoked acceptance, inbox visibility and
  queued push cancellation after opt-out or stale room state.
- `profile-review-tested-hashes.json` records the seven reviewed file hashes.
  All seven remained unchanged before and after the tests.
- Independently verified all 84 candidate hashes, the 78-file local baseline,
  the patch hash, and all 65 preserved files in the assembly manifest. No test
  fixtures are included in the candidate file list.

No blocking finding remains in this dependency overlay. Root release tests and
approval/deployment checks remain separate evidence.
