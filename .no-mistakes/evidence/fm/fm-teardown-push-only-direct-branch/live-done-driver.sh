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
setup done-proof
printf 'harness=claude\n' >> "$FM_HOME/state/task-x1.meta"
"$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" task-x1 --state idle --source fm-recovery --event live-lab-idle >/dev/null
publish
printf 'push_landed_ref=integration/main\n' >> "$FM_HOME/state/task-x1.meta"
printf 'done: branch integration/main pushed to origin\n' > "$FM_HOME/state/task-x1.status"
printf '\nSCENARIO supervisor recognizes verified registered push as done\n'
out=$("$ROOT/bin/fm-crew-state.sh" task-x1)
printf '%s\n' "$out"
case "$out" in 'state: done '*|'state: done'*) ;; *) exit 1 ;; esac
printf 'unpushed follow-up\n' > "$WT/later.txt"
git -C "$WT" add .
commit "$WT" later
printf '\nSCENARIO supervisor rejects a stale done claim after an unpushed commit\n'
out=$("$ROOT/bin/fm-crew-state.sh" task-x1)
printf '%s\n' "$out"
case "$out" in 'state: blocked '*|'state: blocked'*) ;; *) exit 1 ;; esac
