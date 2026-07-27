#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_app_id="69a0e57fa939f578082f8091"
app_file="${root}/base44/.app.jsonc"

fail() {
  echo "Base44 auth deployment check failed: $*" >&2
  exit 1
}

[[ -f "${app_file}" ]] || fail "missing ${app_file}"
app_id="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${app_file}" | head -n 1)"
[[ "${app_id}" == "${expected_app_id}" ]] \
  || fail "linked app ${app_id:-unknown} is not the reviewed SpyClash app"

remote_functions="$(cd "${root}" && npx base44 functions list)"
required_functions=(
  appleAuthBroker
  appleAuthCallback
  autoRegisterUser
  googleAuthCallback
  mobileAuthCallback
)

for function_name in "${required_functions[@]}"; do
  if ! grep -Eq "^[[:space:]]+${function_name}([[:space:]]|$)" <<<"${remote_functions}"; then
    fail "${function_name} is not deployed"
  fi
done

jwks="$(curl --fail --silent --show-error \
  "https://spyclash.com/functions/appleAuthBroker?action=jwks")" \
  || fail "the public appleAuthBroker endpoint is unavailable"
jq -e '.keys | type == "array" and length > 0' <<<"${jwks}" >/dev/null \
  || fail "appleAuthBroker returned an invalid JWKS document"

echo "Base44 Apple/Google authentication deployment is present."
