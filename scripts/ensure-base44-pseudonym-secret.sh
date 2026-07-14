#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/base44/.app.jsonc" | head -n 1)
[ -n "$APP_ID" ] || exit 65

LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/spyclash-secret-list.XXXXXX")
trap 'rm -f "$LIST_FILE"' EXIT HUP INT TERM
if ! npx --yes base44@0.1.4 secrets list > "$LIST_FILE" 2>&1; then
  echo "Unable to verify Base44 secret names; refusing to create or rotate any secret." >&2
  exit 70
fi
if grep -qx 'SPYCLASH_PSEUDONYM_KEY' "$LIST_FILE"; then
  echo "SPYCLASH_PSEUDONYM_KEY is already configured; keeping it stable."
  exit 0
fi

if [ "${1:-}" != "--set" ] || [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "SPYCLASH_PSEUDONYM_KEY is missing." >&2
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID and run $0 --set." >&2
  exit 77
fi

# Use a mode-600 temporary env file because the CLI validates regular files.
# The value is never printed, stored in the repo, or exposed as a process
# argument. Never rotate this key casually: leaderboard aliases are
# intentionally stable for the lifetime of the service.
umask 077
SECRET_FILE=$(mktemp "${TMPDIR:-/tmp}/spyclash-pseudonym.XXXXXX")
trap 'rm -f "$SECRET_FILE" "$LIST_FILE"' EXIT HUP INT TERM
printf 'SPYCLASH_PSEUDONYM_KEY=%s\n' "$(openssl rand -base64 48)" \
  > "$SECRET_FILE"
npx --yes base44@0.1.4 secrets set --env-file "$SECRET_FILE" >/dev/null
rm -f "$SECRET_FILE"
if ! npx --yes base44@0.1.4 secrets list > "$LIST_FILE" 2>&1; then
  echo "Unable to verify Base44 secret names after configuration." >&2
  exit 70
fi

if ! grep -qx 'SPYCLASH_PSEUDONYM_KEY' "$LIST_FILE"; then
  echo "Base44 did not confirm SPYCLASH_PSEUDONYM_KEY." >&2
  exit 70
fi
rm -f "$LIST_FILE"
trap - EXIT HUP INT TERM
echo "SPYCLASH_PSEUDONYM_KEY configured without exposing its value."
