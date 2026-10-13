#!/usr/bin/env bash
# Opt-in credentialed Pi continuity regression on a private tmux socket and
# isolated project/home state. It uses the existing shared Pi auth store without
# copying credentials and pins the captain-approved openai-codex model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_LIVE_E2E pi tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  if [ "${FM_PI_LIVE_STARTUP_ONLY:-0}" = 1 ] && [ -n "${HOME_DIR:-}" ]; then
    cat "$HOME_DIR/state/startup-events.jsonl" "$HOME_DIR/state/.watch-extension.log" "$HOME_DIR/state/.watch-cycle-exits.log" >&2 2>/dev/null || true
  fi
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
AHOY_PROJECT="$LAB/ahoy-project"
HOME_DIR="$LAB/fmhome"
PI_VERSION=$(pi --version)
WATCH_ONLY=${FM_PI_LIVE_WATCH_ONLY:-0}
case "$WATCH_ONLY" in 0|1) ;; *) fail "FM_PI_LIVE_WATCH_ONLY must be 0 or 1" ;; esac
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 out status=0
  out=$(
    cd "$PROJECT" &&
      pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "$preceding" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi Ahoy $label case exited $status: $out"
  case "$expected" in
    bearings)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "Pi Ahoy $label case did not take Bearings: $out"
      ;;
    boundary)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "Pi Ahoy $label near miss was treated as operational: $out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p "$PROJECT/.agents/skills/ahoy" "$PROJECT/.agents/skills/bearings"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$PROJECT/.agents/skills/ahoy/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

run_native_ahoy_regressions() {
  local first_home="$LAB/pi-ahoy-first-home"
  local later_home="$LAB/pi-ahoy-later-home"
  local first_out later_out

  mkdir -p \
    "$AHOY_PROJECT/.pi/extensions/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin" \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$AHOY_PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$AHOY_PROJECT/.pi/extensions/lib/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native Pi Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  first_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$first_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "/ahoy"
  )
  printf '%s\n' "$first_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "Pi native first-message Ahoy did not take Bearings: $first_out"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "Pi native first-message Ahoy did not preserve one session-start execution"

  later_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$later_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "Respond exactly PRIOR_BOUNDARY_ACK." "/ahoy"
  )
  printf '%s\n' "$later_out" | grep -Fq "PRIOR_BOUNDARY_ACK" \
    || fail "Pi native later-message setup did not preserve the genuine captain boundary: $later_out"
  printf '%s\n' "$later_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "Pi native later-message Ahoy gathered Bearings: $later_out"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "Pi native later-message Ahoy reran session start"
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
if [ "$WATCH_ONLY" -eq 0 ] && [ "${FM_PI_LIVE_STARTUP_ONLY:-0}" != 1 ]; then
  run_ahoy_transcript_regressions
  run_native_ahoy_regressions
fi
mkdir -p "$PROJECT/.pi/extensions/lib"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$PROJECT/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$PROJECT/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$PROJECT/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

if [ "${FM_PI_LIVE_STARTUP_ONLY:-0}" = 1 ]; then
  # Keep real Pi, its async startup supervisor, lock acquisition and watcher arm.
  # Replace only the digest runner with a deliberately delayed lock acquisition
  # so this test cannot accidentally pass by owning the lock before session_start.
  cat > "$PROJECT/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
sleep 1
bash "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"
SH
  chmod +x "$PROJECT/bin/fm-sessionstart-run.sh"
  cat > "$PROJECT/.pi/extensions/startup-probe.ts" <<'JS'
import { appendFileSync } from "node:fs";
export default function(pi) {
  pi.on("session_start", (event, ctx) => appendFileSync(
    `${process.env.FM_HOME}/state/startup-events.jsonl`,
    JSON.stringify({ pid: process.pid, reason: event.reason, at: Date.now(),
      session: ctx.sessionManager.getSessionId() }) + "\n"));
  pi.on("agent_start", () => appendFileSync(
    `${process.env.FM_HOME}/state/model-events.jsonl`,
    JSON.stringify({ pid: process.pid, at: Date.now() }) + "\n"));
}
JS
  startup_launch() {
    "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
      "env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_WATCH_EXTENSION_LOG_KEEP_LINES=200 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 pi --approve --no-context-files --no-extensions --session-dir '$LAB/sessions' -e .pi/extensions/startup-probe.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts"
  }
  startup_wait_arm_count() {
    local expected=$1 i=0 count=0
    while [ "$i" -lt 120 ]; do
      count=$(grep -c ' arm generation=.* child=1 ownership=owned' "$HOME_DIR/state/.watch-extension.log" 2>/dev/null || true)
      [ "${count:-0}" -eq "$expected" ] && break
      sleep 0.1
      i=$((i + 1))
    done
    [ "${count:-0}" -eq "$expected" ] || fail "startup expected $expected arm launches, got ${count:-0} (Pi $PI_VERSION)"
    sleep 1
    i=0
    while [ "$i" -lt 150 ]; do
      if [ -f "$HOME_DIR/state/.watch.lock/pid" ] && kill -0 "$(cat "$HOME_DIR/state/.watch.lock/pid")" 2>/dev/null && [ -f "$HOME_DIR/state/.last-watcher-beat" ]; then break; fi
      sleep 0.1
      i=$((i + 1))
    done
    [ -f "$HOME_DIR/state/.watch.lock/pid" ] || fail "startup has no watcher singleton"
    kill -0 "$(cat "$HOME_DIR/state/.watch.lock/pid")" 2>/dev/null || fail "startup watcher is dead"
    [ -f "$HOME_DIR/state/.last-watcher-beat" ] || fail "startup watcher has no beacon"
    count=$(grep -c ' arm generation=.* child=1 ownership=owned' "$HOME_DIR/state/.watch-extension.log" || true)
    [ "$count" -eq "$expected" ] || fail "startup duplicate arm launches (Pi $PI_VERSION)"
  }
  foreign_home="$LAB/foreign-home"
  foreign_project="$LAB/foreign-project"
  foreign_config="$LAB/foreign-pi-config"
  foreign_probe="$PROJECT/.pi/extensions/foreign-pi-probe.ts"
  mkdir -p "$foreign_home/state" "$foreign_home/config" "$foreign_project" "$foreign_config"
  cat > "$foreign_probe" <<'JS'
import { appendFileSync } from "node:fs";
export default function(pi) {
  pi.on("session_start", () => appendFileSync(process.env.FOREIGN_PID_FILE, `${process.pid}\n`));
}
JS
  "$TMUX" -L "$SOCKET" new-session -d -s pi-foreign-owner -c "$foreign_project" \
    "env PI_CODING_AGENT_DIR='$foreign_config' PI_OFFLINE=1 FOREIGN_PID_FILE='$foreign_home/owner.pid' pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions --no-session -e '$foreign_probe'"
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$foreign_home/owner.pid" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$foreign_home/owner.pid" ] || fail "real foreign Pi owner did not start"
  foreign_pid=$(sed -n '1p' "$foreign_home/owner.pid")
  printf '%s\n' "$foreign_pid" > "$foreign_home/state/.lock"
  "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
    "env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME='$foreign_home' FM_ROOT_OVERRIDE='$PROJECT' FM_WATCH_EXTENSION_LOG_KEEP_LINES=200 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 pi --approve --no-context-files --no-extensions --session-dir '$LAB/foreign-candidate-sessions' -e .pi/extensions/startup-probe.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts"
  foreign_candidate_pid=
  i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$foreign_home/state/startup-events.jsonl" ]; then
      foreign_candidate_pid=$(node --input-type=module - "$foreign_home/state/startup-events.jsonl" <<'JS'
import { readFileSync } from "node:fs";
const events = readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse);
process.stdout.write(String(events[0]?.pid ?? ""));
JS
)
    fi
    [ -n "$foreign_candidate_pid" ] && [ -f "$foreign_home/state/.watch-extension.log" ] && \
      grep -Fq 'arm-skip=foreign-lock' "$foreign_home/state/.watch-extension.log" && break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$foreign_candidate_pid" ]; then
    capture >&2
    fail "fresh primary with a foreign lock did not start"
  fi
  grep -Fq 'arm-skip=foreign-lock' "$foreign_home/state/.watch-extension.log" \
    || fail "fresh primary did not report the genuine foreign-owner skip"
  sleep 1.5
  if grep -F "pid=$foreign_candidate_pid " "$foreign_home/state/.watch-extension.log" | grep -Fq ' child=1 ownership=owned'; then
    fail "foreign lock candidate armed after the owner changed or startup retry ran"
  fi
  printf '%s\n' "$foreign_candidate_pid" > "$foreign_home/state/.lock"
  sleep 0.6
  if grep -F "pid=$foreign_candidate_pid " "$foreign_home/state/.watch-extension.log" | grep -Fq ' child=1 ownership=owned'; then
    fail "a callback armed after the foreign lock changed to the candidate"
  fi
  send_prompt /quit
  wait_pid_dead "$foreign_candidate_pid" || fail "foreign-lock candidate did not quit"
  "$TMUX" -L "$SOCKET" kill-session -t pi-foreign-owner 2>/dev/null || true
  wait_pid_dead "$foreign_pid" || fail "foreign Pi owner did not stop"
  "$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  startup_launch
  startup_wait_arm_count 1
  first_pid=$(cat "$HOME_DIR/state/.lock")
  send_prompt /new
  startup_wait_arm_count 2
  [ "$(cat "$HOME_DIR/state/.lock")" = "$first_pid" ] || fail "/new replaced Pi process"
  send_prompt /quit
  wait_pid_dead "$first_pid" || fail "first Pi did not exit"
  "$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  startup_launch
  startup_wait_arm_count 3
  second_pid=$(cat "$HOME_DIR/state/.lock")
  [ "$second_pid" != "$first_pid" ] || fail "restart did not create a fresh Pi process"
  send_prompt /quit
  wait_pid_dead "$second_pid" || fail "restarted Pi did not exit"
  if ! EVENTS="$HOME_DIR/state/startup-events.jsonl" LOG="$HOME_DIR/state/.watch-extension.log" MODEL_EVENTS="$HOME_DIR/state/model-events.jsonl" node --input-type=module <<'JS'
import { existsSync, readFileSync } from "node:fs";
const events = readFileSync(process.env.EVENTS, "utf8").trim().split("\n").map(JSON.parse);
if (events.length !== 3 || events[0].reason !== "startup" || events[1].reason !== "new" || events[2].reason !== "startup")
  throw new Error(`unexpected Pi lifecycle: ${JSON.stringify(events)}`);
if (events[0].pid !== events[1].pid || events[0].pid === events[2].pid || events[0].session === events[1].session)
  throw new Error(`PID/session boundaries not proven: ${JSON.stringify(events)}`);
const log = readFileSync(process.env.LOG, "utf8");
const modelEvents = existsSync(process.env.MODEL_EVENTS)
  ? readFileSync(process.env.MODEL_EVENTS, "utf8").trim().split("\n").map(JSON.parse) : [];
for (const event of events) {
  const arm = log.split("\n").find(line => line.includes(`pid=${event.pid} `) &&
    line.includes(" child=1 ownership=owned") && Date.parse(line.split(" ")[0]) >= event.at);
  if (!arm) throw new Error("missing initial arm after lifecycle event");
  const armAt = Date.parse(arm.split(" ")[0]);
  if (modelEvents.some(turn => turn.pid === event.pid && turn.at >= event.at && turn.at < armAt))
    throw new Error("model turn preceded startup activation");
}
for (const pid of [events[0].pid, events[2].pid])
  if (!log.split("\n").some(line => line.includes(`pid=${pid} `) && line.includes("ownership=missing")))
    throw new Error(`fresh process ${pid} did not exercise late lock acquisition`);
console.log(`ok - Pi startup events ${JSON.stringify(events)}`);
JS
  then
    fail "real Pi startup lifecycle assertions failed"
  fi
  printf 'ok - Pi %s fresh restart and same-process /new auto-arm once without model turns; a live foreign Pi lock stays unarmed\n' "$PI_VERSION"
  exit 0
fi

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

if [ "$WATCH_ONLY" -eq 0 ]; then
  send_prompt "/calm"
  sleep 0.2
  send_prompt "Reply exactly CALM_LIVE_WORKING_VISIBLE"
  i=0
  while [ "$i" -lt 240 ]; do
    pane=$(capture)
    if printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱'; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
    || fail "Calm did not show the working ship on the credentialed provider path"
  printf '%s\n' "$pane" | grep -Fq "Working..." \
    && fail "Calm left Pi's stock working row visible on the credentialed provider path"
  wait_for_exact_line "CALM_LIVE_WORKING_VISIBLE" 120 \
    || fail "Pi did not settle the Calm working-ship provider probe"
  pane=$(capture)
  printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
    && fail "Calm left the working ship on screen after the run settled"
  printf '%s\n' "$pane" | grep -Fq "calm transcript" \
    && fail "Calm added a persistent Calm status row on the credentialed provider path"
  send_prompt "/calm"
  sleep 0.2
fi

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Start supervision with fm_watch_arm_pi and never use bash to arm supervision. Three watcher notifications will name LIVE_WAKE_1 through LIVE_WAKE_3. After each one, run bin/fm-wake-drain.sh, handle and acknowledge it, then reply exactly HANDLED_1, HANDLED_2, or HANDLED_3 to match that notification."
i=0
while [ "$i" -lt 120 ]; do
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Eq 'watcher: started Pi extension arm child|Pi extension already owns an arm child'; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
printf '%s\n' "$pane" | grep -Eq 'watcher: started Pi extension arm child|Pi extension already owns an arm child' \
  || fail "Pi did not render the initial watcher ownership result"

wake_number=1
while [ "$wake_number" -le 3 ]; do
  printf 'done: pi live e2e LIVE_WAKE_%s\n' "$wake_number" >> "$HOME_DIR/state/pi-e2e.status"
  i=0
  cycle_count=0
  while [ "$i" -lt 240 ]; do
    if [ -f "$HOME_DIR/state/.watch-cycle-exits.log" ]; then
      cycle_count=$(grep -Ec 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null || true)
    fi
    [ "$cycle_count" -ge "$wake_number" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  [ "$cycle_count" -ge "$wake_number" ] \
    || fail "Pi extension did not ledger-link successor $wake_number after its actionable close"
  wait_for_exact_line "HANDLED_$wake_number" 120 \
    || fail "Pi did not drain and settle notification $wake_number after its extension-owned successor started"
  wake_number=$((wake_number + 1))
done

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_result_count=$(printf '%s\n' "$pane" | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$arm_tool_result_count" -eq 1 ] || fail "Pi model re-armed from memory instead of the extension (tool-result count $arm_tool_result_count)"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"
lab_pid_is_safe "$watcher_pid" || fail "refusing to stop watcher outside the isolated live-Pi lab"
lab_pid_is_safe "$arm_pid" || fail "refusing to stop arm outside the isolated live-Pi lab"
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "watcher: FAILED - intentional isolated live-E2E stop"' \
  'exit 1' > "$PROJECT/bin/fm-watch-arm.sh"
chmod +x "$PROJECT/bin/fm-watch-arm.sh"
kill -TERM "$arm_pid" 2>/dev/null || fail "could not intentionally stop the isolated arm chain"
wait_pid_dead "$watcher_pid" || fail "intentionally stopped watcher stayed alive"
wait_pid_dead "$arm_pid" || fail "intentionally stopped arm stayed alive"
sleep 2
alarm=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" FM_GUARD_GRACE=1 \
  FM_SUPERVISION_MODEL=extension "$PROJECT/bin/fm-guard.sh" 2>&1)
printf '%s\n' "$alarm" | grep -Fq 'WATCHER DOWN - SUPERVISION IS OFF' \
  || fail "an intentionally stopped live Pi chain did not raise the genuine outage alarm: $alarm"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

if [ "$WATCH_ONLY" -eq 1 ]; then
  printf 'ok - Pi %s live E2E covered repeated successor handoffs and a genuine stopped-chain alarm\n' "$PI_VERSION"
else
  printf 'ok - Pi %s live E2E covered repeated successor handoffs and a genuine stopped-chain alarm, plus Calm and Ahoy regressions\n' "$PI_VERSION"
fi
