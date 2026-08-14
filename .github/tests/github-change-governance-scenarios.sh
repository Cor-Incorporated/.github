#!/usr/bin/env bash

set -euo pipefail

workflow_file="${1:-.github/workflows/github-change-governance.yml}"
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

gate_script="$fixture_root/governance-step.sh"
awk '
  $0 == "      - name: 変更管理を検査する" { found_step = 1; next }
  found_step && $0 == "        env:" { in_env = 1; next }
  in_env && $0 == "        run: |" { in_script = 1; next }
  in_script && /^      - / { exit }
  in_script {
    sub(/^          /, "")
    print
  }
  END {
    if (!in_script) {
      exit 1
    }
  }
' "$workflow_file" > "$gate_script"

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$MOCK_CURL_CALLS"
cat "$MOCK_RESPONSE"
EOF
chmod +x "$fake_bin/curl"

write_response() {
  local author="$1"
  local issues_json="$2"
  jq -n \
    --arg author "$author" \
    --argjson issues "$issues_json" \
    '{data:{repository:{pullRequest:{author:{login:$author},
      closingIssuesReferences:{nodes:$issues}}}}}' \
    > "$fixture_root/response.json"
}

run_gate() {
  local event_name="$1"
  : > "$fixture_root/curl-calls.log"
  PATH="$fake_bin:$PATH" \
    EVENT_NAME="$event_name" \
    GH_TOKEN=dummy \
    GRAPHQL_URL=https://api.github.invalid/graphql \
    MOCK_CURL_CALLS="$fixture_root/curl-calls.log" \
    MOCK_RESPONSE="$fixture_root/response.json" \
    POLICY_OWNER=terisuke \
    PR_NUMBER=42 \
    REPOSITORY=Cor-Incorporated/.github \
    bash "$gate_script" > "$fixture_root/run.log" 2>&1
}

assert_gate() {
  local name="$1"
  local expected="$2"
  local event_name="$3"

  if run_gate "$event_name"; then
    actual=pass
  else
    actual=fail
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name: expected=$expected actual=$actual"
    sed -n '1,80p' "$fixture_root/run.log" >&2
  fi
}

write_response terisuke '[]'
assert_gate "terisuke本人はIssueなしで許可" pass pull_request_target

write_response other-member '[]'
assert_gate "他メンバーはIssueなしでは拒否" fail pull_request_target

write_response other-member \
  '[{"number":123,"repository":{"nameWithOwner":"Cor-Incorporated/.github"}}]'
assert_gate "他メンバーは同一リポジトリIssueがあれば許可" pass pull_request_target

write_response other-member \
  '[{"number":123,"repository":{"nameWithOwner":"Cor-Incorporated/opencode"}}]'
assert_gate "他リポジトリIssueだけでは拒否" fail pull_request_target

write_response other-member '[]'
assert_gate "merge groupはPR検証済みとして許可" pass merge_group
if [ -s "$fixture_root/curl-calls.log" ]; then
  fail "merge groupで不要なAPI呼び出しを行った"
else
  pass "merge groupではAPIを呼ばない"
fi

printf '\n結果: %d PASS / %d FAIL\n' "$passes" "$failures"
if ((failures > 0)); then
  exit 1
fi
