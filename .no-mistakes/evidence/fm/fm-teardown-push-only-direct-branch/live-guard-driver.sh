#!/usr/bin/env bash
set -eo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.live-guards.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
for v in ${!FM_@}; do case "$v" in *_OVERRIDE|FM_GATE_REFUSE_BYPASS|FM_TEST_SEAM) unset "$v" ;; esac; done
unset TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX
export FM_HOME="$LAB/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'claude\n' > "$FM_HOME/config/crew-harness"
printf '%s\n' '- demo [direct-PR forge=push-only] - disposable validation' > "$FM_HOME/data/projects.md"
git init -q --initial-branch=main "$FM_HOME/projects/demo"
run() {
  local id=$1 expected=$2 base=$3 ref=$4
  local brief_args=() spawn_args=()
  if [ -n "$base" ]; then brief_args+=(--base-branch "$base"); spawn_args+=(--base-branch "$base"); fi
  if [ -n "$ref" ]; then spawn_args+=(--push-landed-ref "$ref"); fi
  "$ROOT/bin/fm-brief.sh" "$id" demo --mode direct-PR --forge push-only "${brief_args[@]}" >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Implement the requested disposable change.').replace('{FIRSTMATE_SPEC}', 'Deliver to the registered branch.')
open(p,'w').write(s)
PY
  printf '\nSCENARIO %s\n' "$id"
  set +e
  out=$("$ROOT/bin/fm-spawn.sh" "$id" "$FM_HOME/projects/demo" --mode direct-PR --yolo off "${spawn_args[@]}" 2>&1)
  rc=$?
  set -e
  printf '%s\nexit=%s\n' "$out" "$rc"
  test "$rc" != 0
  case "$out" in *"$expected"*) ;; *) exit 1 ;; esac
  test ! -e "$FM_HOME/state/$id.meta"
  printf 'No task record published.\n'
}
run no-registration 'requires --push-landed-ref' '' ''
run no-base "requires --base-branch 'integration/main'" '' integration/main
run wrong-base 'must match the registered push-landed ref' integration/main release/main
