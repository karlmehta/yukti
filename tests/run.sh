#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Checks of the engine that need no device. Each case builds its own flow files
# in a fresh directory, runs yukti on them and asserts what came out: the exit
# status AND a piece of the output. A case that asserted the status alone would
# pass on any refusal, including one for a reason the case never meant.
#
# Written for the bash a Mac ships (/bin/bash 3.2) as well as for the CI runner:
# no mapfile, no associative arrays, no GNU-only flags.
#
#   tests/run.sh            run every case, exit 1 if any failed
#   KEEP=1 tests/run.sh     the same, and leave the case directories behind
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # no -e: one failed case must not hide the ones after it

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YUKTI="$ROOT/yukti"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/yukti-tests.XXXXXX")" || exit 1
[ -n "$WORK" ] || { echo "no temporary directory for the cases" >&2; exit 1; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

pass=0; fail=0; case_dir=""

# A fresh directory per case: a file left by one case cannot satisfy another.
new_case(){ case_dir="$WORK/$1"; mkdir -p "$case_dir"; }

# step <json> - one step of a flow file, written as JSON.
# flow_file <path> <step>... - a flow file with these steps.
flow_file(){ local f="$1" sep="" s; shift
  { printf '{ "name": "%s", "steps": [' "$(basename "$f" .json)"
    for s in "$@"; do printf '%s\n  %s' "$sep" "$s"; sep=","; done
    printf '\n] }\n'; } > "$f"; }

# chain <dir> <n> - flow.json includes b1.json, b1 includes b2, ... bn. Every
# file carries one wait of its own, so a flow that builds has n+1 steps: the
# count proves the builder went all the way down, not just that it said yes.
chain(){ local d="$1" n="$2" i
  flow_file "$d/flow.json" '{ "do": "wait", "value": "1" }' '{ "do": "include", "value": "b1.json" }'
  i=1
  while [ "$i" -lt "$n" ]; do
    flow_file "$d/b$i.json" '{ "do": "wait", "value": "1" }' "{ \"do\": \"include\", \"value\": \"b$((i + 1)).json\" }"
    i=$((i + 1))
  done
  flow_file "$d/b$n.json" '{ "do": "wait", "value": "1" }'; }

# chain_names <n> - the chain as the engine prints it: flow.json -> b1.json ...
chain_names(){ local n="$1" i=1 s="flow.json"
  while [ "$i" -le "$n" ]; do s="$s -> b$i.json"; i=$((i + 1)); done
  printf '%s' "$s"; }

# expect <name> <status> <text> <command...> - run the command, compare the
# status and look for the text in what it printed (colour codes removed).
expect(){ local name="$1" want="$2" text="$3" out st; shift 3
  out="$("$@" 2>&1)"; st=$?
  out="$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
  if [ "$st" -eq "$want" ] && case "$out" in *"$text"*) true;; *) false;; esac; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n     wanted status %s and "%s"\n     got status %s:\n%s\n' \
      "$name" "$want" "$text" "$st" "$(printf '%s' "$out" | sed 's/^/       /')"
  fi; }

check(){ "$YUKTI" flow --check "$1"; }

# ── include depth (#93) ──────────────────────────────────────────────────────
new_case include-3
chain "$case_dir" 3
expect "include: three blocks deep builds" 0 " - 4 steps" check "$case_dir/flow.json"

new_case include-8
chain "$case_dir" 8
expect "include: eight blocks deep builds" 0 " - 9 steps" check "$case_dir/flow.json"

new_case include-9
chain "$case_dir" 9
expect "include: a ninth block is refused with the chain" 1 \
  "includes may go 8 blocks deep - 'b9.json' would be block 9: $(chain_names 9)" check "$case_dir/flow.json"

new_case include-self
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b1.json" }'
expect "include: a block that includes itself is refused" 1 \
  "a block cannot include itself, directly or in a circle: flow.json -> b1.json -> b1.json" \
  check "$case_dir/flow.json"

new_case include-circle
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b1.json" }'
expect "include: a circle of blocks is refused" 1 \
  "a block cannot include itself, directly or in a circle: flow.json -> b1.json -> b2.json -> b1.json" \
  check "$case_dir/flow.json"

# A parameter passed at the top reaches the fourth block. The variable is not
# in the environment, and the builder refuses a variable it cannot fill, so the
# flow builds only if the value travelled down through every level.
new_case include-with
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "with": { "YUKTI_TEST_DEEP": "Today" } }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitFor", "value": "${YUKTI_TEST_DEEP}" }'
expect "include: a parameter reaches the fourth block" 0 " - 1 steps" \
  env -u YUKTI_TEST_DEEP "$YUKTI" flow --check "$case_dir/flow.json"

# The name arriving is not the value arriving. A value with the runner's field
# separator in it passes the include - parameters are not checked for it there
# - and is refused only by the step that uses it, so this refusal, named after
# the fourth block, is the value itself reaching the bottom.
new_case include-with-value
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "with": { "YUKTI_TEST_DEEP": "a\u001fb" } }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitFor", "value": "${YUKTI_TEST_DEEP}" }'
expect "include: the value of a parameter reaches the fourth block" 1 \
  "step 1 'waitFor' of block 'b4.json': \"value\" contains a character the runner separates fields with" \
  env -u YUKTI_TEST_DEEP "$YUKTI" flow --check "$case_dir/flow.json"

# ── a failing step on a device (#94) ─────────────────────────────────────────
# The device is tests/fake-sdk/platform-tools/adb, put first in PATH through
# ANDROID_HOME (the engine derives its SDK path from it). Each case gets its own
# directory for the fake, the results and $TMPDIR.
dev_case(){ new_case "$1"; mkdir -p "$case_dir/adb" "$case_dir/res" "$case_dir/tmp"; }

# screen <file> <node>... - a uiautomator dump holding these nodes.
screen(){ local f="$1" n; shift
  { printf '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hierarchy rotation="0">'
    for n in "$@"; do printf '%s' "$n"; done
    printf '</hierarchy>\n'; } > "$f"; }

# node <class> <resource-id> <text> [focused] [password] - one node of a dump.
node(){ printf '<node index="0" text="%s" resource-id="com.example:id/%s" class="android.widget.%s" package="com.example" content-desc="%s" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="%s" scrollable="false" long-clickable="false" password="%s" selected="false" bounds="[0,%d][1080,%d]" />' \
  "$3" "$2" "$1" "$3" "${4:-false}" "${5:-false}" "$(node_y "$2")" "$(( $(node_y "$2") + 120 ))"; }
# Each node its own band, the same on every run: the place comes from the id.
node_y(){ local y; y="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; printf '%d' $(( (y % 15) * 140 + 100 )); }

# run_flow <flow> [VAR=value...] - the flow against the fake, output kept in
# $case_dir/out and the status in $run_status.
run_flow(){ local f="$1"; shift
  env -u ANDROID_SDK_ROOT ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android \
    FAKE_ADB_DIR="$case_dir/adb" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" "$@" \
    "$YUKTI" flow "$f" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }

# Assertions for one case collect into $why; verdict prints it.
begin(){ case_name="$1"; why=""; }
no(){ why="$why
     $*"; }
status_is(){ [ "$run_status" -eq "$1" ] || no "status $run_status, wanted $1"; }
file_full(){ [ -s "$case_dir/$1" ] || no "$1 is missing or empty"; }
file_absent(){ [ ! -e "$case_dir/$1" ] || no "$1 exists and should not"; }
has(){ grep -qF -- "$2" "$case_dir/$1" 2>/dev/null || no "$1 lacks: $2"; }
lacks(){ ! grep -qiF -- "$2" "$case_dir/$1" 2>/dev/null || no "$1 holds: $2"; }
# The fake was asked something - otherwise a case that passed against a real
# adb found first in PATH would look exactly the same.
fake_used(){ [ -s "$case_dir/adb/log" ] || no "the fake adb was never called"; }
verdict(){ if [ -z "$why" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$case_name"
  else fail=$((fail + 1)); printf 'FAIL %s%s\n     output:\n%s\n' "$case_name" "$why" "$(sed 's/^/       /' "$case_dir/out.txt" 2>/dev/null)"; fi; }

MARK="Synthetic marker text"   # on every screen, never secret: a mask that
                               # blanked the whole tree must not pass

dev_case capture-missing-id
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)" "$(node TextView marker "$MARK")"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a failed step leaves its screen and its tree"
status_is 1; fake_used
file_full res/flow-fail.png; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
has res/flow.xml "not on screen"; has res/flow.xml "screen: flow-fail.png"; has res/flow.xml "tree: flow-fail.xml"
verdict

# What a flow typed is masked in the tree, and so is a password field however
# it arrived there. The typed value carries an & and a quote: the dump writes
# the & escaped and puts the value in '...' because of the quote, and a mask
# that looked only for the raw text, or only inside "...", would miss it. The
# second field holds its hint and a piece of an earlier attempt - what a React
# Native input showed after a retyped value.
LEFTOVER="<node index=\"0\" text='Type a message...beth&amp;co\"x@exa' resource-id=\"com.example:id/chat\" class=\"android.widget.EditText\" package=\"com.example\" content-desc=\"\" focused=\"false\" password=\"false\" bounds=\"[0,1900][1080,2000]\" />"
dev_case capture-mask
screen "$case_dir/adb/dump-1.xml" "$(node EditText email @TYPED@ true)" "$LEFTOVER" \
  "$(node EditText pin 'Static&amp;pin&quot;9' false true)" "$(node TextView marker "$MARK")"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_EMAIL}" }' \
  '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json" TEST_EMAIL='beth&co"x@example.invalid'
begin "capture: typed text and password fields are masked in the tree"
status_is 1; fake_used; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml 'beth&amp;co'; lacks res/flow-fail.xml '@example.invalid'; lacks res/flow-fail.xml 'Static&amp;pin'
lacks res/flow-fail.xml 'co"x@exa'; has res/flow-fail.xml 'resource-id="com.example:id/chat"'
verdict

# The step that types is the one that fails: its value is only in the record
# of the running step. Every burst of keys loses its last character, so the
# field ends up holding the value with gaps - what an emulator under load
# leaves - which a mask that matched whole values would let through.
dev_case capture-type-fails
screen "$case_dir/adb/dump-1.xml" "$(node EditText password @TYPED@ true)" "$(node TextView marker "$MARK")"
: > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_PASSWORD}" }'
run_flow "$case_dir/flow.json" TEST_PASSWORD='Pa&ss"w0rd!Long'
begin "capture: a failed type step is masked, gaps included"
status_is 1; fake_used; file_full res/flow-fail.xml
has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml 'Pa&amp;ss'; lacks res/flow-fail.xml 'wrd!Lon'
verdict

dev_case capture-screencap-fails
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo fail > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a screenshot that fails still leaves the result and the reason"
status_is 1; fake_used; file_absent res/flow-fail.png; file_full res/flow-fail.xml
has res/flow.xml "not on screen"; has res/flow.xml "screen not captured"
verdict

dev_case capture-screencap-hangs
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo hang > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
t0=$SECONDS; run_flow "$case_dir/flow.json"; took=$((SECONDS - t0))
begin "capture: a screenshot that never answers is given up on"
status_is 1; fake_used
[ "$took" -lt 40 ] || no "the run took ${took}s"
has res/flow.xml "not on screen"; has res/flow.xml "screen not captured"
verdict

# A tap by coordinates reads no tree. The tree that is kept was read by the
# step before it, and the result says so instead of passing it off as the
# screen of the failure.
dev_case capture-older-tree
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
: > "$case_dir/adb/tap-fails"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }' '{ "do": "tap", "x": 10, "y": 10 }'
run_flow "$case_dir/flow.json"
begin "capture: a tree read by an earlier step is named as such"
status_is 1; fake_used
has res/flow.xml "tree: flow-fail.xml (read by step 1)"
verdict

# A condition that cannot read the screen stops the run before its step is
# recorded: the failure lands on "00 flow", and the screen is still taken.
dev_case capture-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0" }' \
  '{ "do": "tap", "x": 10, "y": 10, "when": { "visibleId": "title" } }'
run_flow "$case_dir/flow.json"
begin "capture: a condition that cannot read the screen still leaves the screen"
status_is 1; fake_used; file_full res/flow-fail.png
has res/flow.xml 'name="00 flow"'; has res/flow.xml "screen: flow-fail.png"; has res/flow.xml "tree: none"
verdict

dev_case capture-pass
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "capture: a flow that passes leaves no failure files"
status_is 0; fake_used; file_full res/flow.xml
file_absent res/flow-fail.png; file_absent res/flow-fail.xml
verdict

# A step of a block four levels down is named with its block in the result.
dev_case capture-deep-block
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json" }'
flow_file "$case_dir/b1.json" '{ "do": "include", "value": "b2.json" }'
flow_file "$case_dir/b2.json" '{ "do": "include", "value": "b3.json" }'
flow_file "$case_dir/b3.json" '{ "do": "include", "value": "b4.json" }'
flow_file "$case_dir/b4.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "results: a step four blocks down is named with its block"
status_is 1; fake_used; has res/flow.xml "[b4.json] waitForId missing"
verdict

# ── fix the app, or restart the device (#96) ─────────────────────────────────
# What the engine knows for sure is the device's - a screen that could not be
# read, a screenshot not taken - and is a JUnit <error>. Everything else stays
# a <failure>. The exit status is 1 either way.
red_is(){ has res/flow.xml "<$1 message="; has res/flow.xml "type=\"$2\""
  has res/flow.xml "failures=\"$3\" errors=\"$4\""; }

dev_case junit-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "junit: a screen that cannot be read is an error"
status_is 1; fake_used; red_is error DeviceError 0 1
verdict

# One read of three fails, the next ones work, the element is not there: the
# step failed on what it saw. A mark left by the bad read must not decide.
dev_case junit-one-bad-read
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
cp "$case_dir/adb/dump-1.xml" "$case_dir/adb/dump-2.xml"; cp "$case_dir/adb/dump-1.xml" "$case_dir/adb/dump-3.xml"
screen "$case_dir/adb/dump-4.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 3 }'
run_flow "$case_dir/flow.json"
begin "junit: a missed read does not make a missing element an error"
status_is 1; fake_used; red_is failure StepFailed 1 0; has res/flow.xml "not on screen"
verdict

dev_case junit-missing
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "junit: a missing element is a failure"
status_is 1; fake_used; red_is failure StepFailed 1 0
verdict

dev_case junit-screenshot
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
echo fail > "$case_dir/adb/screencap"
flow_file "$case_dir/flow.json" '{ "do": "screenshot", "value": "home" }'
run_flow "$case_dir/flow.json"
begin "junit: a screenshot the device did not take is an error"
status_is 1; fake_used; red_is error DeviceError 0 1; has res/flow.xml "screenshot failed"
verdict

# A name the engine refuses is the author's mistake, not the device's.
dev_case junit-screenshot-name
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "screenshot", "value": "../home" }'
run_flow "$case_dir/flow.json"
begin "junit: a screenshot name the engine refuses is a failure"
status_is 1; red_is failure StepFailed 1 0; has res/flow.xml "must not contain"
verdict

dev_case junit-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0" }' \
  '{ "do": "tap", "x": 10, "y": 10, "when": { "visibleId": "title" } }'
run_flow "$case_dir/flow.json"
begin "junit: a condition that cannot read the screen is an error on 00 flow"
status_is 1; fake_used; red_is error FlowError 0 1; has res/flow.xml 'name="00 flow"'
verdict

dev_case junit-bad-file
printf '{ "steps": [' > "$case_dir/flow.json"
run_flow "$case_dir/flow.json"
begin "junit: a flow file that does not build is a failure"
status_is 1; red_is failure FlowFailed 1 0
verdict

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
