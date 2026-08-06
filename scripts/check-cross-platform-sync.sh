#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web_root="${project_root}/.web-reference/spyclash-web"
ios_client="${project_root}/SpyClash/Services/Base44Client.swift"
ios_model="${project_root}/SpyClash/Models/SpyModels.swift"
backend="${project_root}/base44/functions/gameRoomAction/main.ts"
community_backend="${project_root}/base44/functions/communityAction/main.ts"
web_auth_transport="${web_root}/src/lib/socialAuth.js"

fail() {
  echo "cross-platform sync check failed: $*" >&2
  exit 1
}

[[ -d "${web_root}/src" ]] || fail "missing canonical Web checkout at ${web_root}"
[[ -f "${ios_client}" ]] || fail "missing iOS Base44 client"
[[ -f "${backend}" ]] || fail "missing canonical gameRoomAction backend"
[[ -f "${community_backend}" ]] || fail "missing canonical communityAction backend"
[[ -f "${web_auth_transport}" ]] || fail "missing canonical Web social-auth transport"

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
  update_game_mode
  update_game_duration
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

for field in intro_started_at game_started_at game_duration_seconds game_paused_at game_paused_total_seconds question_phase; do
  rg -q --fixed-strings "${field}" "${backend}" || fail "backend is missing ${field}"
  rg -q --fixed-strings "${field}" "${ios_model}" || fail "iOS model is missing ${field}"
  rg -q --fixed-strings "${field}" "${web_root}/src" || fail "Web is missing ${field}"
done

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
