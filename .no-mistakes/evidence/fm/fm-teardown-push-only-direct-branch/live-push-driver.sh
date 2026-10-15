#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/Users/stan/.no-mistakes/evidence/01M4ZHEKX4F3553H2JS9NQE9BJ
LAB=$(mktemp -d "$ROOT/.live-push.XXXXXX")
SOCKET="$ROOT/.live-push.sock"
trap 'tmux -S "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"; rm -f "$SOCKET"' EXIT
export HOME="$LAB/user" XDG_CONFIG_HOME="$LAB/user/config" XDG_CACHE_HOME="$LAB/user/cache"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export TMPDIR="$LAB/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
for v in ${!FM_@}; do case "$v" in *_OVERRIDE|FM_GATE_REFUSE_BYPASS|FM_TEST_SEAM) unset "$v" ;; esac; done
unset TMUX TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMUX_TMPDIR="$LAB/tmux"
mkdir -p "$TMUX_TMPDIR"
tmux -S "$SOCKET" -f /dev/null new-session -d -s fm-lab -n keep -x 80 -y 24 "sleep 600"
export TMUX="$SOCKET,0,0"
commit() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid commit -qm "$2"; }
setup() {
  local name=$1
  C="$LAB/$name"
  "$ROOT/bin/fm-lab-home.sh" create "$C/home" >/dev/null
  export FM_HOME="$C/home" TREEHOUSE_ROOT="$C/pool"
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  git init -q --bare --initial-branch=main "$C/origin.git"
  git clone -q "$C/origin.git" "$C/project"
  printf 'base\n' > "$C/project/base.txt"
  git -C "$C/project" add .
  commit "$C/project" base
  git -C "$C/project" push -q origin main
  git -C "$C/project" remote set-head origin main
  WT=$(cd "$C/project" && treehouse get --lease --no-fetch -b fm/task-x1)
  printf 'feature\n' > "$WT/feature.txt"
  git -C "$WT" add .
  commit "$WT" feature
  HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)
  tmux -S "$SOCKET" new-window -d -t fm-lab -n fm-task-x1 -c "$FM_HOME" "sleep 600"
  cat > "$FM_HOME/state/task-x1.meta" <<META
worktree=$WT
project=$C/project
kind=ship
mode=direct-PR
window=fm-lab:fm-task-x1
endpoint_task_id=task-x1
spawn_gen=live-validation-task-x1
META
}
publish() {
  git -C "$WT" push -q origin HEAD:refs/heads/integration/main
  git -C "$WT" update-ref -d refs/remotes/origin/integration/main
}
run_cleanup() {
  set +e
  "$ROOT/bin/fm-teardown.sh" task-x1 > "$C/cleanup.log" 2>&1
  RC=$?
  set -e
  cat "$C/cleanup.log"
  printf 'cleanup exit=%s\n' "$RC"
}
retained() {
  test "$RC" = 1
  test -f "$FM_HOME/state/task-x1.meta"
  test "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE"
  printf 'Task record and original HEAD retained.\n'
  tmux -S "$SOCKET" kill-window -t fm-lab:fm-task-x1
}
setup registered
publish
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
printf '\nSCENARIO registered branch push permits cleanup without force\n'
printf 'local HEAD=%s; remote registered ref=' "$HEAD_BEFORE"
git -C "$WT" ls-remote origin refs/heads/integration/main
if [ "$C" = "$LAB/registered" ]; then
  set +e
  "$ROOT/bin/.baseline-teardown.sh" task-x1 > "$C/baseline.log" 2>&1
  baseline_rc=$?
  set -e
  printf 'BASELINE same registered push before fix: exit=%s\n' "$baseline_rc"
  cat "$C/baseline.log"
  test "$baseline_rc" = 1
  test -e "$FM_HOME/state/task-x1.meta"
  test "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE"
fi
run_cleanup
test "$RC" = 0
test ! -e "$FM_HOME/state/task-x1.meta"
printf 'Task record removed; returned slot state: '
git -C "$WT" status --short
(cd "$C/project" && treehouse status)
setup unregistered
publish
printf '\nSCENARIO identical push without registration refuses cleanup\n'
run_cleanup
retained
setup not-contained
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
git -C "$C/project" push -q origin main:refs/heads/integration/main
printf '\nSCENARIO registered remote branch lacking HEAD refuses cleanup\n'
run_cleanup
retained
setup deleted
publish
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
git -C "$WT" fetch -q origin
# Leave a stale local tracking ref, but delete the authoritative remote branch.
git -C "$C/project" push -q origin :refs/heads/integration/main
printf '\nSCENARIO stale tracking ref cannot prove a deleted remote branch landed\n'
run_cleanup
retained
setup dirty
publish
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
printf 'uncommitted\n' >> "$WT/feature.txt"
printf '\nSCENARIO dirty registered-push copy refuses cleanup\n'
run_cleanup
retained
test "$(tail -1 "$WT/feature.txt")" = uncommitted
setup advanced
publish
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
git -C "$C/project" fetch -q origin
git -C "$C/project" checkout -qb integration/main origin/integration/main
printf 'newer remote work\n' > "$C/project/newer.txt"
git -C "$C/project" add .
commit "$C/project" newer
git -C "$C/project" push -q origin integration/main
printf '\nSCENARIO registered branch advanced beyond delivered HEAD still permits cleanup\n'
run_cleanup
test "$RC" = 0
test ! -e "$FM_HOME/state/task-x1.meta"
setup default-branch
# Remote main receives the feature, while local origin/main remains stale.
git -C "$C/project" push -q origin "$HEAD_BEFORE:refs/heads/main"
printf '\nSCENARIO existing default-branch landing permits cleanup without registration\n'
run_cleanup
test "$RC" = 0
test ! -e "$FM_HOME/state/task-x1.meta"
printf '\nAll live scenarios completed; disposable lab removed by EXIT trap.\n'
