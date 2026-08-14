#!/usr/bin/env bash

set -euo pipefail

repair_script="${1:-.github/scripts/repair-secret-scan-ruleset.sh}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

passes=0
failures=0

pass() {
  passes=$((passes + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

if [ ! -x "$repair_script" ]; then
  printf 'FAIL: 修復スクリプトが存在しないか実行できません: %s\n' "$repair_script" >&2
  exit 1
fi

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_GH_CALLS"

if [[ " $* " == *" --method PUT "* ]]; then
  cat > "$MOCK_GH_PAYLOAD"
  cp "$MOCK_GH_PAYLOAD" "$MOCK_RULESET"
  exit 0
fi

endpoint=""
for arg in "$@"; do
  case "$arg" in
    repos/*/rulesets|repos/*/rulesets/*)
      endpoint="$arg"
      ;;
  esac
done

case "$endpoint" in
  repos/*/rulesets)
    printf '[{"id":42,"name":"シークレット検査の必須化"}]\n'
    ;;
  repos/*/rulesets/42)
    cat "$MOCK_RULESET"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/gh"

write_ruleset() {
  local create_exemption="$1"
  jq -n --argjson create_exemption "$create_exemption" '{
    id: 42,
    name: "シークレット検査の必須化",
    rules: [
      {
        type: "pull_request",
        parameters: {
          allowed_merge_methods: ["merge", "squash", "rebase"],
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_approving_review_count: 0,
          required_review_thread_resolution: false,
          required_reviewers: []
        }
      },
      {
        type: "workflows",
        parameters: {
          do_not_enforce_on_create: $create_exemption,
          workflows: [{
            path: ".github/workflows/gitleaks.yml",
            ref: "refs/heads/main",
            repository_id: 123456
          }]
        }
      }
    ]
  }' > "$fixture_root/ruleset.json"
}

run_repair() {
  : > "$fixture_root/gh-calls.log"
  : > "$fixture_root/payload.json"
  PATH="$fake_bin:$PATH" \
    MOCK_GH_CALLS="$fixture_root/gh-calls.log" \
    MOCK_GH_PAYLOAD="$fixture_root/payload.json" \
    MOCK_RULESET="$fixture_root/ruleset.json" \
    bash "$repair_script" "$@" > "$fixture_root/run.log" 2>&1
}

write_ruleset false
if run_repair --check; then
  fail "作成例外が無効なlive rulesetを検出できなかった"
else
  pass "作成例外が無効なlive rulesetを拒否"
fi

if run_repair --apply; then
  if jq -e '
    [.rules[] | select(.type == "workflows") |
      .parameters.do_not_enforce_on_create] == [true] and
    ([.rules[] | select(.type == "pull_request")] | length) == 1
  ' "$fixture_root/payload.json" >/dev/null; then
    pass "workflowsルールだけを作成可能へ修復"
  else
    fail "修復payloadが既存ルールを保持していない"
  fi
else
  fail "作成例外を修復できなかった"
fi

write_ruleset true
if run_repair --check; then
  pass "作成例外が有効なlive rulesetを受理"
else
  fail "正常なlive rulesetを拒否した"
fi

printf '\n結果: %d PASS / %d FAIL\n' "$passes" "$failures"
if ((failures > 0)); then
  exit 1
fi
