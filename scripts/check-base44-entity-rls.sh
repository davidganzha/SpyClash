#!/bin/zsh

set -euo pipefail

root="$(cd "$(dirname "${0:A}")/.." && pwd)"
entities_root="$root/base44/entities"
missing=()
tautological_reads=()
missing_authority_fls=()

for schema in "$entities_root"/*.jsonc; do
  entity="$(jq -r '.name // empty' "$schema")"
  [[ -n "$entity" ]] || {
    print -u2 -- "Invalid entity schema: $schema"
    exit 1
  }

  # User is Base44's built-in authenticated principal. Every custom entity must
  # declare explicit create/read/update/delete policy in source control.
  if [[ "$entity" != "User" ]] && ! jq -e \
    '.rls.create and .rls.read and .rls.update and .rls.delete' \
    "$schema" >/dev/null; then
    missing+=("$schema")
  fi

  # This condition checks the authenticated User against itself and therefore
  # does not constrain the entity row. Record ownership must use data.*.
  if jq -e '.rls.read.user_condition.id == "{{user.id}}"' \
    "$schema" >/dev/null; then
    tautological_reads+=("$schema")
  fi
done

authority_fields=(
  'Friendship:blocked_by_id'
  'Friendship:request_event_id'
  'GameHistory:player_user_id'
  'GameHistory:match_id'
  'GameRoom:participant_user_ids'
  'GameRoom:match_id'
  'GameRoom:terminal_intent'
  'GameRoom:game_started_event_id'
  'GameRoom:game_finished_event_id'
  'RoomInvite:notification_event_id'
  'WordPack:owner_user_id'
)
for authority in "${authority_fields[@]}"; do
  entity="${authority%%:*}"
  field="${authority#*:}"
  schema="$entities_root/$entity.jsonc"
  if ! jq -e --arg field "$field" '
    .properties[$field].rls.read.user_condition.role == "admin" and
    .properties[$field].rls.write.user_condition.role == "admin"
  ' "$schema" >/dev/null; then
    missing_authority_fls+=("$entity.$field")
  fi
done

if (( ${#missing[@]} )); then
  print -u2 -- "Custom Base44 entities missing complete RLS:"
  printf '%s\n' "${missing[@]}" >&2
  exit 1
fi

if (( ${#tautological_reads[@]} )); then
  print -u2 -- "Base44 entity reads contain a user-self tautology:"
  printf '%s\n' "${tautological_reads[@]}" >&2
  exit 1
fi

if (( ${#missing_authority_fls[@]} )); then
  print -u2 -- "Server authority fields missing admin-only read/write FLS:"
  printf '%s\n' "${missing_authority_fls[@]}" >&2
  exit 1
fi

print -- "Base44 entity RLS completeness check passed."
