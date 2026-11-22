#!/usr/bin/env bash
# 実際に Git で merge し、launchctl はスタブに差し替えて常駐 rmv への影響を避ける。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'cd / && find "$TMP" -depth -delete' EXIT
mkdir -p "$TMP/bin" "$TMP/hooks"
cp "$ROOT/.githooks/post-merge" "$TMP/hooks/post-merge"

cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ "${LAUNCHCTL_FAIL:-0}" = 1 ]; then
  printf 'launchctl error\n' >&2
  exit 1
fi
STUB
chmod +x "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH" LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$LAUNCHCTL_LOG"

git init -q --template= -b main "$TMP/repo"
cd "$TMP/repo"
git config core.hooksPath "$TMP/hooks"
git config user.name 'rmv test'
git config user.email 'rmv-test@example.invalid'
git config commit.gpgsign false
git commit -q --allow-empty -m base
git checkout -qb topic
printf 'first\n' > example
git add example
git commit -qm first

git checkout -qb side main
git merge --ff-only -q topic
[ ! -s "$LAUNCHCTL_LOG" ]

git checkout -q main
git merge --ff-only -q topic
service="gui/$(id -u)/com.ktsm.harness-rmv"
[ "$(cat "$LAUNCHCTL_LOG")" = "kickstart -k $service" ]

git checkout -q topic
printf 'second\n' >> example
git commit -qam second
git checkout -q main
head_before=$(git rev-parse HEAD)
git merge --squash --ff -q topic
[ "$(git rev-parse HEAD)" = "$head_before" ]
[ "$(cat "$LAUNCHCTL_LOG")" = "kickstart -k $service" ]

git restore --staged --worktree -- example
LAUNCHCTL_FAIL=1 git merge --ff-only -q topic 2>"$TMP/stderr"
[ "$(git rev-parse HEAD)" = "$(git rev-parse topic)" ]
[ "$(cat "$TMP/stderr")" = "post-merge: rmv restart failed (launchctl kickstart -k $service)" ]
[ "$(wc -l < "$LAUNCHCTL_LOG" | tr -d ' ')" = 2 ]

echo 'ok post-merge main, side branch, squash and restart failure'
