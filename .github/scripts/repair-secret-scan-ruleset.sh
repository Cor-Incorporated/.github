#!/usr/bin/env bash

set -euo pipefail

mode="${1:---check}"
organization="${ORGANIZATION:-Cor-Incorporated}"
probe_repository="${PROBE_REPOSITORY:-cor-os}"
ruleset_name="${RULESET_NAME:-シークレット検査の必須化}"

case "$mode" in
  --check|--apply)
    ;;
  *)
    printf 'usage: %s [--check|--apply]\n' "$0" >&2
    exit 2
    ;;
esac

for command in gh jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR: %s is required\n' "$command" >&2
    exit 2
  fi
done

rulesets="$(gh api "repos/${organization}/${probe_repository}/rulesets")"
ruleset_id="$(jq -r --arg name "$ruleset_name" \
  '[.[] | select(.name == $name) | .id] | if length == 1 then .[0] else empty end' \
  <<<"$rulesets")"

if [ -z "$ruleset_id" ]; then
  printf 'ERROR: inherited ruleset was not resolved uniquely: %s\n' "$ruleset_name" >&2
  exit 2
fi

read_ruleset() {
  gh api "repos/${organization}/${probe_repository}/rulesets/${ruleset_id}"
}

is_create_safe() {
  jq -e '
    ([.rules[] | select(.type == "workflows")] | length) > 0 and
    ([.rules[] | select(.type == "workflows") |
      .parameters.do_not_enforce_on_create] | all(. == true))
  ' >/dev/null
}

current="$(read_ruleset)"
if is_create_safe <<<"$current"; then
  printf 'OK: required workflows allow repository and default branch creation\n'
  exit 0
fi

if [ "$mode" = "--check" ]; then
  printf 'ERROR: required workflows block repository or default branch creation\n' >&2
  exit 1
fi

updated_rules="$(jq '
  .rules | map(
    if .type == "workflows" then
      .parameters.do_not_enforce_on_create = true
    else
      .
    end
  )
' <<<"$current")"
payload="$(jq -n --argjson rules "$updated_rules" '{rules: $rules}')"

printf '%s' "$payload" | gh api --method PUT \
  "orgs/${organization}/rulesets/${ruleset_id}" --input - >/dev/null

readback="$(read_ruleset)"
if ! is_create_safe <<<"$readback"; then
  printf 'ERROR: ruleset readback did not preserve the creation exemption\n' >&2
  exit 1
fi

printf 'UPDATED: required workflows now allow repository and default branch creation\n'
