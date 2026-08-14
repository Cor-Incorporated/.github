#!/usr/bin/env bash

set -euo pipefail

workflow_file="${1:-.github/workflows/gitleaks.yml}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

bash_runner="${BASH_BIN:-bash}"
if ((BASH_VERSINFO[0] < 4)) && [ -x /opt/homebrew/bin/bash ]; then
  bash_runner=/opt/homebrew/bin/bash
fi

failures=0
passes=0

pass() {
  passes=$((passes + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

scan_script="$fixture_root/scan-step.sh"
awk '
  $0 == "      - name: 検査する" { found_step = 1; next }
  found_step && $0 == "        run: |" { in_script = 1; next }
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
' "$workflow_file" > "$scan_script"

remote_repo="$fixture_root/origin.git"
scenario_repo="$fixture_root/scenario"
git init --quiet --bare "$remote_repo"
git init --quiet --initial-branch=dev "$scenario_repo"
git -C "$scenario_repo" config core.hooksPath /dev/null
git -C "$scenario_repo" config user.name "Scenario Test"
git -C "$scenario_repo" config user.email "scenario@example.invalid"

printf 'baseline\n' > "$scenario_repo/app.txt"
git -C "$scenario_repo" add app.txt
git -C "$scenario_repo" commit --quiet -m "baseline"
base_sha="$(git -C "$scenario_repo" rev-parse HEAD)"
git -C "$scenario_repo" remote add origin "$remote_repo"
git -C "$scenario_repo" push --quiet --set-upstream origin dev

git -C "$scenario_repo" switch --quiet -c feature
printf 'first change\n' >> "$scenario_repo/app.txt"
git -C "$scenario_repo" commit --quiet -am "first change"
printf 'second change\n' >> "$scenario_repo/app.txt"
git -C "$scenario_repo" commit --quiet -am "second change"

fake_bin="$fixture_root/fake-bin"
capture_file="$fixture_root/gitleaks-args.txt"
mkdir -p "$fake_bin"
cat > "$fake_bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GITLEAKS_CAPTURE"
EOF
chmod +x "$fake_bin/gitleaks"

run_with_fake_gitleaks() {
  local event_name="$1"
  local event_base_sha="$2"
  local event_base_ref="$3"
  local before_sha="$4"
  local default_branch="$5"

  : > "$capture_file"
  (
    cd "$scenario_repo"
    PATH="$fake_bin:$PATH" \
      GITLEAKS_CAPTURE="$capture_file" \
      GITHUB_EVENT_NAME="$event_name" \
      BASE_SHA="$event_base_sha" \
      BASE_REF="$event_base_ref" \
      BEFORE_SHA="$before_sha" \
      DEFAULT_BRANCH="$default_branch" \
      "$bash_runner" "$scan_script"
  ) > "$fixture_root/run.log" 2>&1
}

assert_range() {
  local name="$1"
  local expected_range="$2"
  shift 2

  if ! run_with_fake_gitleaks "$@"; then
    fail "$name: 検査ステップが異常終了した"
    sed -n '1,80p' "$fixture_root/run.log" >&2
    return
  fi

  if grep -Fq -- "--log-opts=$expected_range" "$capture_file"; then
    pass "$name"
  else
    fail "$name: 期待範囲 $expected_range / 実引数 $(<"$capture_file")"
  fi
}

assert_full_scan() {
  local name="$1"
  shift

  if ! run_with_fake_gitleaks "$@"; then
    fail "$name: 検査ステップが異常終了した"
    sed -n '1,80p' "$fixture_root/run.log" >&2
    return
  fi

  if grep -Fq -- '--log-opts=' "$capture_file"; then
    fail "$name: フルスキャンに差分範囲が付いた: $(<"$capture_file")"
  else
    pass "$name"
  fi
}

assert_rejects_missing_pr_base() {
  local name="PRメタデータ欠落時は全履歴へ退避せず安全に停止"

  if run_with_fake_gitleaks pull_request '' '' '' ''; then
    fail "$name: 全履歴スキャンまたは無範囲検査へ進んだ"
  elif [ -s "$capture_file" ]; then
    fail "$name: 停止前に gitleaks を実行した: $(<"$capture_file")"
  else
    pass "$name"
  fi
}

assert_range "forkを含むdev向けPRはイベントのbase SHAだけを検査" \
  "$base_sha..HEAD" pull_request "$base_sha" dev '' dev

git -C "$scenario_repo" update-ref -d refs/remotes/origin/dev
assert_range "base SHAとremote ref欠落時はPRのbase refをfetchして復元" \
  "$base_sha..HEAD" pull_request '' dev '' dev

assert_range "merge queueはmerge groupのbase SHAだけを検査" \
  "$base_sha..HEAD" merge_group "$base_sha" dev '' dev

assert_range "複数コミットpushはbefore SHA以降をすべて検査" \
  "$base_sha..HEAD" push '' '' "$base_sha" dev

assert_range "push前SHAを取得できない場合はdefault branchから復元" \
  "$base_sha..HEAD" push '' '' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef dev

git -C "$scenario_repo" update-ref -d refs/remotes/origin/dev
assert_range "新規ブランチpushはdefault branchとの分岐以降を検査" \
  "$base_sha..HEAD" push '' '' 0000000000000000000000000000000000000000 dev

assert_full_scan "月次scheduleは監査用フルスキャン" schedule '' '' '' dev

assert_rejects_missing_pr_base

run_gitleaks_integration() {
  local integration_repo="$fixture_root/integration"
  local integration_log="$fixture_root/integration.log"
  local integration_base

  if ! command -v gitleaks >/dev/null 2>&1; then
    printf 'SKIP: gitleaks実バイナリの陽性・陰性検査（未インストール）\n'
    return
  fi

  git init --quiet --initial-branch=dev "$integration_repo"
  git -C "$integration_repo" config core.hooksPath /dev/null
  git -C "$integration_repo" config user.name "Scenario Test"
  git -C "$integration_repo" config user.email "scenario@example.invalid"
  git -C "$integration_repo" remote add origin "$remote_repo"

  cat > "$integration_repo/.gitleaks.toml" <<'EOF'
title = "gitleaks workflow scenario"

[[rules]]
id = "scenario-finding"
description = "Scenario test finding"
regex = '''SCENARIO_FINDING_[A-Z0-9]{16}'''
keywords = ["SCENARIO_FINDING_"]
EOF
  printf 'SCENARIO_FINDING_HISTORICAL000001\n' > "$integration_repo/historical.txt"
  git -C "$integration_repo" add .gitleaks.toml historical.txt
  git -C "$integration_repo" commit --quiet -m "historical finding"
  integration_base="$(git -C "$integration_repo" rev-parse HEAD)"
  git -C "$integration_repo" switch --quiet -c safe-change
  printf 'safe implementation\n' > "$integration_repo/feature.txt"
  git -C "$integration_repo" add feature.txt
  git -C "$integration_repo" commit --quiet -m "safe change"

  if (
    cd "$integration_repo"
    GITHUB_EVENT_NAME=pull_request \
      BASE_SHA="$integration_base" \
      BASE_REF=dev \
      BEFORE_SHA='' \
      DEFAULT_BRANCH=dev \
      "$bash_runner" "$scan_script"
  ) > "$integration_log" 2>&1; then
    pass "base側の既存検出は安全なPRを阻まない"
  else
    fail "base側の既存検出で安全なPRが失敗した"
    sed -n '1,80p' "$integration_log" >&2
  fi

  printf 'SCENARIO_FINDING_NEWVALUE00000000\n' > "$integration_repo/introduced.txt"
  git -C "$integration_repo" add introduced.txt
  git -C "$integration_repo" commit --quiet -m "introduce finding"

  if (
    cd "$integration_repo"
    GITHUB_EVENT_NAME=pull_request \
      BASE_SHA="$integration_base" \
      BASE_REF=dev \
      BEFORE_SHA='' \
      DEFAULT_BRANCH=dev \
      "$bash_runner" "$scan_script"
  ) > "$integration_log" 2>&1; then
    fail "PRが新規混入させた検出対象を停止できなかった"
  else
    pass "PRが新規混入させた検出対象は停止する"
  fi
}

run_gitleaks_integration

printf '\n結果: %d PASS / %d FAIL\n' "$passes" "$failures"
if ((failures > 0)); then
  exit 1
fi
