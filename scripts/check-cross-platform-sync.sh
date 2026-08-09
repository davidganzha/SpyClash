#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web_root="${project_root}/.web-reference/spyclash-web"
canonical_app_id="69a0e57fa939f578082f8091"
root_app_config="${project_root}/base44/.app.jsonc"
game_room_entity="${project_root}/base44/entities/GameRoom.jsonc"
ios_client="${project_root}/SpyClash/Services/Base44Client.swift"
ios_model="${project_root}/SpyClash/Models/SpyModels.swift"
ios_game_view="${project_root}/SpyClash/Views/GameView.swift"
ios_local_game_view="${project_root}/SpyClash/Views/LocalGameView.swift"
ios_online_experience="${project_root}/SpyClash/Views/OnlineGameExperience.swift"
backend="${project_root}/base44/functions/gameRoomAction/main.ts"
backend_timer_policy="${project_root}/base44/functions/gameRoomAction/game-timer-policy.ts"
backend_result_policy="${project_root}/base44/functions/gameRoomAction/room-result-policy.ts"
backend_vote_policy="${project_root}/base44/functions/gameRoomAction/detective-vote-policy.ts"
backend_multi_spy_policy="${project_root}/base44/functions/gameRoomAction/multi-spy-policy.ts"
backend_vote_lease_recovery="${project_root}/base44/functions/gameRoomAction/detective-vote-lease-recovery.ts"
backend_room_projection="${project_root}/base44/functions/gameRoomAction/room-projection.ts"
community_backend="${project_root}/base44/functions/communityAction/main.ts"
web_auth_transport="${web_root}/src/lib/socialAuth.js"
web_app_policy="${web_root}/src/lib/appParamsPolicy.js"
web_game_page="${web_root}/src/pages/Game.jsx"
web_local_game_page="${web_root}/src/pages/LocalGame.jsx"
web_game_sync="${web_root}/src/lib/gameRoomSync.js"
web_local_game_rules="${web_root}/src/lib/localGameRules.js"
web_online_presentation="${web_root}/src/lib/onlineGamePresentation.js"
web_detective_vote_retry="${web_root}/src/lib/detectiveVoteRetry.js"
web_multi_spy_rules="${web_root}/src/lib/multiSpyRules.js"

fail() {
  echo "cross-platform sync check failed: $*" >&2
  exit 1
}

[[ -d "${web_root}/src" ]] || fail "missing canonical Web checkout at ${web_root}"
[[ -f "${root_app_config}" ]] || fail "missing canonical Base44 app binding"
[[ -f "${game_room_entity}" ]] || fail "missing canonical GameRoom entity"
[[ -f "${ios_client}" ]] || fail "missing iOS Base44 client"
[[ -f "${ios_game_view}" ]] || fail "missing iOS game view"
[[ -f "${ios_local_game_view}" ]] || fail "missing iOS local game view"
[[ -f "${ios_online_experience}" ]] || fail "missing iOS online experience"
[[ -f "${backend}" ]] || fail "missing canonical gameRoomAction backend"
[[ -f "${backend_timer_policy}" ]] || fail "missing canonical game timer policy"
[[ -f "${backend_result_policy}" ]] || fail "missing canonical room result policy"
[[ -f "${backend_vote_policy}" ]] || fail "missing canonical detective vote policy"
[[ -f "${backend_multi_spy_policy}" ]] || fail "missing canonical multi-spy policy"
[[ -f "${backend_vote_lease_recovery}" ]] || fail "missing detective vote lease recovery"
[[ -f "${backend_room_projection}" ]] || fail "missing canonical room projection"
[[ -f "${community_backend}" ]] || fail "missing canonical communityAction backend"
[[ -f "${web_auth_transport}" ]] || fail "missing canonical Web social-auth transport"
[[ -f "${web_app_policy}" ]] || fail "missing canonical Web app identity policy"
[[ -f "${web_game_page}" ]] || fail "missing canonical Web game page"
[[ -f "${web_local_game_page}" ]] || fail "missing canonical Web local game page"
[[ -f "${web_game_sync}" ]] || fail "missing canonical Web game timer policy"
[[ -f "${web_local_game_rules}" ]] || fail "missing canonical Web local-game rules"
[[ -f "${web_online_presentation}" ]] || fail "missing canonical Web online presentation"
[[ -f "${web_detective_vote_retry}" ]] || fail "missing canonical Web detective-vote retry helper"
[[ -f "${web_multi_spy_rules}" ]] || fail "missing canonical Web multi-spy rules"

rg -q --fixed-strings "\"id\": \"${canonical_app_id}\"" "${root_app_config}" \
  || fail "repository is not linked to the canonical SpyClash Base44 app"
rg -q --fixed-strings "static let appID = \"${canonical_app_id}\"" "${ios_client}" \
  || fail "iOS is not pinned to the canonical SpyClash Base44 app"
rg -q --fixed-strings "SPYCLASH_BASE44_APP_ID = \"${canonical_app_id}\"" "${web_app_policy}" \
  || fail "Web is not pinned to the canonical SpyClash Base44 app"

required_auth_functions=(
  appleAuthBroker
  appleAuthCallback
  googleAuthCallback
  mobileAuthCallback
)

for function_name in "${required_auth_functions[@]}"; do
  [[ -f "${project_root}/base44/functions/${function_name}/function.jsonc" ]] \
    || fail "missing canonical ${function_name} function config"
  [[ -f "${project_root}/base44/functions/${function_name}/main.ts" ]] \
    || fail "missing canonical ${function_name} implementation"
done

for auth_page in "${web_root}/src/pages/Login.jsx" "${web_root}/src/pages/Register.jsx"; do
  rg -q --fixed-strings 'buildSocialLoginUrl' "${auth_page}" \
    || fail "$(basename "${auth_page}") bypasses the reviewed social-auth redirect"
done

rg -q --fixed-strings '/auth/sso/login' "${web_auth_transport}" \
  || fail "Web social auth is not routed through Base44 custom SSO"
rg -q --fixed-strings 'auth_provider' "${web_auth_transport}" \
  || fail "Web social auth cannot select the Google upstream provider"

if rg -n 'loginWithProvider\(|AppleSignInSheet|popup_origin' \
  "${web_root}/src/pages/Login.jsx" \
  "${web_root}/src/pages/Register.jsx" \
  "${web_root}/src/lib/socialAuth.js"; then
  fail "Web social auth reintroduced the fragile SDK or popup redirect path"
fi

if rg -n 'entities\.GameRoom\.(create|update|delete|filter|list|subscribe|get)' "${web_root}/src"; then
  fail "Web source still bypasses gameRoomAction with direct GameRoom access"
fi

required_shared_actions=(
  get_room
  create_room
  join_room
  leave_room
  begin_ready_check
  toggle_ready
  update_lobby_state
  arm_roulette
  complete_game_start
  mark_role_card_read
  pause_game
  resume_game
  advance_question
  advance_association
  start_association
  stop_association_spin
  mark_answer_heard
  continue_round
  request_vote
  cast_detective_vote
  submit_spy_guess
  finalize_expired_room
  vote_play_again
  reset_room_for_replay
)

for action in "${required_shared_actions[@]}"; do
  rg -q --fixed-strings "\"${action}\"" "${backend}" \
    || fail "backend does not expose ${action}"
  rg -q --fixed-strings "\"${action}\"" "${ios_client}" "${project_root}/SpyClash/Views" \
    || fail "iOS does not implement ${action}"
  rg -q --fixed-strings "\"${action}\"" "${web_root}/src" \
    || fail "Web does not implement ${action}"
done

# iOS still supports these narrow legacy writes for compatibility with rooms
# created before atomic lobby snapshots. Web must use update_lobby_state only.
legacy_ios_lobby_actions=(
  update_game_mode
  update_game_duration
)

for action in "${legacy_ios_lobby_actions[@]}"; do
  rg -q --fixed-strings "\"${action}\"" "${backend}" \
    || fail "backend does not expose legacy ${action}"
  rg -q --fixed-strings "\"${action}\"" "${ios_client}" "${project_root}/SpyClash/Views" \
    || fail "iOS does not implement legacy ${action}"
done

for field in intro_started_at game_started_at game_duration_seconds game_paused_at game_paused_total_seconds question_phase; do
  rg -q --fixed-strings "${field}" "${backend}" || fail "backend is missing ${field}"
  rg -q --fixed-strings "${field}" "${ios_model}" || fail "iOS model is missing ${field}"
  rg -q --fixed-strings "${field}" "${web_root}/src" || fail "Web is missing ${field}"
done

# Timer expiry and detective exclusion are one shared server-owned contract.
# Guard every shipped client against silently restoring the retired 30-second
# guess phase or the old plurality/majority exclusion rule.
if rg -n 'POST_GAME_GUESS_SECONDS|postGameGuessSecondsRemaining|guessRemainingSeconds' \
  "${backend}" \
  "${backend_timer_policy}" \
  "${backend_result_policy}" \
  "${ios_model}" \
  "${ios_game_view}" \
  "${ios_online_experience}" \
  "${web_game_page}" \
  "${web_local_game_page}" \
  "${web_game_sync}" \
  "${web_local_game_rules}"; then
  fail "retired post-game guess grace was reintroduced"
fi

rg -q --fixed-strings 'return "spy";' "${backend_result_policy}" \
  || fail "backend does not award the spy at the authoritative timer deadline"
rg -q --fixed-strings 'previewRoom.winner = "spy"' "${ios_game_view}" \
  || fail "iOS preview does not award the spy at timer zero"
rg -q --fixed-strings 'LocalGameDeadlinePolicy.outcome' "${ios_local_game_view}" \
  || fail "iOS local game does not route timer zero through the deadline policy"
rg -q --fixed-strings 'finishLocalGameAtDeadline()' "${ios_local_game_view}" \
  || fail "iOS local game does not finish at timer zero"
rg -q --fixed-strings 'winner = .spy' "${ios_local_game_view}" \
  || fail "iOS local game does not award the spy at timer zero"
if rg -n 'beginSpyGuess\(' "${ios_local_game_view}"; then
  fail "iOS local game reintroduced the retired post-deadline guess transition"
fi
rg -q --fixed-strings 'winner: "spy"' "${web_local_game_rules}" \
  || fail "Web local game does not award the spy at timer zero"

# Full exclusion generalizes legacy N-1 to N-S for a server-owned active spy
# count. The one-spy case remains exactly N-1; clients consume the projected
# threshold and never infer hidden roles locally.
rg -q --fixed-strings 'activeEmails.length - activeSpyCount' "${backend_vote_policy}" \
  || fail "backend detective exclusion is not pinned to N-S"
rg -q --fixed-strings 'reconcileDetectiveVoteCastAfterActiveIdentityLease' "${backend}" \
  || fail "backend does not reconcile detective votes after lifecycle lease contention"
rg -q --fixed-strings 'var exclusionVoteThreshold' "${ios_model}" \
  || fail "iOS does not expose the server detective exclusion threshold"
rg -q --fixed-strings 'serverExclusionVoteThreshold' "${ios_model}" \
  || fail "iOS does not consume exclusion_vote_threshold"
rg -q --fixed-strings 'room?.exclusion_vote_threshold' "${web_online_presentation}" \
  || fail "Web does not consume exclusion_vote_threshold"

# Multi-spy is one additive, backward-compatible contract. The host owns the
# public lobby count; the server samples identities once and projections keep
# the team private unless the teammate switch or terminal reveal permits it.
for field in lobby_spy_count spies_know_each_other spy_emails; do
  rg -q --fixed-strings "\"${field}\"" "${game_room_entity}" \
    || fail "GameRoom entity is missing ${field}"
  rg -q --fixed-strings "${field}" "${backend}" "${backend_multi_spy_policy}" "${backend_room_projection}" \
    || fail "backend multi-spy contract is missing ${field}"
  rg -q --fixed-strings "${field}" "${ios_model}" "${ios_client}" "${ios_game_view}" \
    || fail "iOS multi-spy contract is missing ${field}"
  rg -q --fixed-strings "${field}" "${web_root}/src" \
    || fail "Web multi-spy contract is missing ${field}"
done

rg -q --fixed-strings 'MAX_SPY_COUNT = 3' "${backend_multi_spy_policy}" \
  || fail "backend multi-spy hard maximum is not three"
rg -q --fixed-strings 'min(3, max(1, playerCount / 3))' "${ios_model}" \
  || fail "iOS does not enforce the approved spy-count bands"
rg -q --fixed-strings 'MAX_SPIES = 3' "${web_multi_spy_rules}" \
  || fail "Web multi-spy hard maximum is not three"
rg -q --fixed-strings 'serverSpyAssignment(room)' "${backend}" \
  || fail "backend does not own online spy assignment"
rg -q --fixed-strings 'MULTI_SPY_CAPABILITY = "multi_spy_v1"' "${backend_multi_spy_policy}" \
  || fail "backend does not gate legacy clients from multi-spy rooms"
rg -q --fixed-strings 'multiSpyCapability = "multi_spy_v1"' "${ios_client}" \
  || fail "iOS does not advertise multi_spy_v1"
rg -q --fixed-strings 'MULTI_SPY_CLIENT_CAPABILITY = "multi_spy_v1"' "${web_multi_spy_rules}" \
  || fail "Web does not advertise multi_spy_v1"
rg -q --fixed-strings 'revealed_spy_emails' "${backend_room_projection}" "${ios_model}" "${web_root}/src" \
  || fail "cross-platform ejected-spy reveal contract is incomplete"

if rg -n 'spyIdx|plan\.spy_email|spy_email:\s*spy' "${web_root}/src/pages/Room.jsx"; then
  fail "Web reintroduced client-owned online spy assignment"
fi

# Every detective ballot is bound to one server-issued round. The room
# projection and both clients must preserve that identity through conflict
# recovery, including the server's pending-terminal reconciliation signal.
rg -q --fixed-strings '"detective_vote_round_id": {' "${game_room_entity}" \
  || fail "GameRoom entity is missing detective_vote_round_id"

rg -q --fixed-strings 'room?.detective_vote_round_id' "${backend}" \
  || fail "backend does not bind detective votes to detective_vote_round_id"
rg -q --fixed-strings 'body?.expected_vote_round_id' "${backend}" \
  || fail "backend does not validate expected_vote_round_id"
rg -q --fixed-strings 'code: "terminal_reconciliation_pending"' "${backend}" \
  || fail "backend does not expose terminal_reconciliation_pending"
rg -q --fixed-strings 'detective_vote_round_id: clean(room.detective_vote_round_id)' \
  "${backend_room_projection}" \
  || fail "room projection omits detective_vote_round_id"
rg -q --fixed-strings 'terminal_reconciliation_pending: terminalReconciliationPending(room)' \
  "${backend_room_projection}" \
  || fail "room projection omits terminal_reconciliation_pending"

rg -q --fixed-strings 'case detectiveVoteRoundID = "detective_vote_round_id"' "${ios_model}" \
  || fail "iOS model is missing detective_vote_round_id"
rg -q --fixed-strings 'case terminalReconciliationPending = "terminal_reconciliation_pending"' \
  "${ios_model}" \
  || fail "iOS model is missing terminal_reconciliation_pending"
rg -q --fixed-strings 'case expectedDetectiveVoteRoundID = "expected_vote_round_id"' "${ios_client}" \
  || fail "iOS client payload is missing expected_vote_round_id"
rg -q --fixed-strings 'expectedVoteRoundID: castScope.voteRoundID' "${ios_game_view}" \
  || fail "iOS GameView does not send the active detective vote round"
rg -q --fixed-strings 'authoritative.terminalReconciliationPending == true' "${ios_game_view}" \
  || fail "iOS GameView does not handle terminal_reconciliation_pending"

rg -q --fixed-strings 'room?.detective_vote_round_id' "${web_detective_vote_retry}" \
  || fail "Web detective-vote helper is missing detective_vote_round_id"
rg -q --fixed-strings 'room?.terminal_reconciliation_pending === true' \
  "${web_detective_vote_retry}" \
  || fail "Web detective-vote helper does not handle terminal_reconciliation_pending"
rg -q --fixed-strings 'recoverDetectiveVoteCastConflict' "${web_detective_vote_retry}" "${web_game_page}" \
  || fail "Web Game is not wired to detective-vote conflict recovery"
rg -q --fixed-strings 'currentRoom.detective_vote_round_id' "${web_game_page}" \
  || fail "Web Game does not read detective_vote_round_id"
rg -q --fixed-strings 'expected_vote_round_id: voteRoundID' "${web_game_page}" \
  || fail "Web Game does not send expected_vote_round_id"
rg -q --fixed-strings 'expected_vote_round_id: expectedVoteRoundID' "${web_game_page}" \
  || fail "Web detective-vote retry does not preserve expected_vote_round_id"

rg -q --fixed-strings '/functions/gameRoomAction' "${web_root}/src/lib/gameRoomActions.js" \
  || fail "Web room transport is not routed through gameRoomAction"
rg -q --fixed-strings '/functions/gameRoomAction' "${ios_client}" \
  || fail "iOS room transport is not routed through gameRoomAction"

community_transport="${web_root}/src/lib/communityActions.js"
[[ -f "${community_transport}" ]] || fail "Web Community transport is missing"

required_community_actions=(
  state
  search
  send_request
  accept
  decline
  invite_to_room
  accept_room_invite
  decline_room_invite
  consume_room_invite
)

for action in "${required_community_actions[@]}"; do
  rg -q --fixed-strings "\"${action}\"" "${community_backend}" \
    || fail "backend Community does not expose ${action}"
  rg -q --fixed-strings "\"${action}\"" "${project_root}/SpyClash" \
    || fail "iOS Community does not implement ${action}"
  rg -q --fixed-strings "\"${action}\"" "${web_root}/src" \
    || fail "Web Community does not implement ${action}"
done

rg -q --fixed-strings '/functions/communityAction' "${web_root}/src/lib" \
  || fail "Web Community transport is not routed through communityAction"
if rg -n 'base44\.entities\.(Friendship|RoomInvite|CommunityProfile|ProfileComment)' "${web_root}/src"; then
  fail "Web Community still bypasses communityAction with direct entity access"
fi

if [[ -d "${web_root}/dist" ]]; then
  rg -q --fixed-strings 'gameRoomAction' "${web_root}/dist" \
    || fail "built Web bundle does not contain gameRoomAction"
  if rg -n 'GameRoom\.(create|update|delete|filter|list|subscribe)' "${web_root}/dist"; then
    fail "built Web bundle still contains direct GameRoom CRUD"
  fi
fi

echo "cross-platform room and Community contracts are aligned across backend, iOS, and Web"
