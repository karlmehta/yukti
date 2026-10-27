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
  env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_CONFIG ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
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

# ── how often type and clear read the screen (#106) ──────────────────────────
# A read of the screen costs seconds on a device, so the count of reads is what
# these cases assert, beside the outcome. The fake counts them in `dumps` (adb)
# and `describes` (idb).
VALUE='synthetic.value+22@x.y'   # 22 characters, three bursts of eight

# field <id> <focused> <x1,y1,x2,y2> [text] - an EditText at a given place.
field(){ printf '<node index="0" text="%s" resource-id="com.example:id/%s" class="android.widget.EditText" package="com.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="%s" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[%s][%s]" />' \
  "${4:-@TYPED@}" "$1" "$2" "$(printf '%s' "$3" | cut -d, -f1-2)" "$(printf '%s' "$3" | cut -d, -f3-4)"; }
reads_are(){ local got; got="$(cat "$case_dir/adb/dumps" 2>/dev/null || echo 0)"
  [ "$got" = "$1" ] || no "the screen was read $got times, wanted $1"; }
typed_is(){ [ "$(cat "$case_dir/adb/typed" 2>/dev/null)" = "$1" ] || no "the field holds '$(cat "$case_dir/adb/typed" 2>/dev/null)', wanted '$1'"; }

dev_case type-one-read
screen "$case_dir/adb/dump-1.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_flow "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type: three bursts, the field read once before and once after"
status_is 0; fake_used; reads_are 2; typed_is "$VALUE"
lacks out.txt "lost characters"
verdict

dev_case type-retry
screen "$case_dir/adb/dump-1.xml" "$(field email true 100,500,900,600)"
printf '1' > "$case_dir/adb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_flow "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type: a burst that lost a character is caught after the last one and typed again"
status_is 0; typed_is "$VALUE"
has out.txt "attempt 1 lost characters"; has out.txt "22 characters arrived on attempt 2"
verdict

dev_case clear-two-reads
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: one read finds the field, one after the delete proves it empty"
status_is 0; fake_used; reads_are 2; typed_is ""
has out.txt "field empty at 500,550"
verdict

dev_case clear-hint
printf 'old text' > "$case_dir/adb/typed"; printf 'Email' > "$case_dir/adb/hint"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a field showing its hint takes a third read to be called empty"
status_is 0; reads_are 3; typed_is ""
has out.txt "field empty at 500,550"
verdict

dev_case clear-leftover
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,500,900,600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,500,900,600 'left over')"
screen "$case_dir/adb/dump-3.xml" "$(field email true 100,500,900,600 'left ove')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: text the probing delete still shortens is not called empty"
status_is 1; reads_are 3
has out.txt "the field still holds text after select-all and delete"
verdict

dev_case clear-moved
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: the field the keyboard moved up is still the field"
status_is 0; reads_are 2; typed_is ""
has out.txt "the field moved to 100 900 900 1000"
verdict

dev_case clear-other-shape
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 0,300,1080,420)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a focused field of another width is another field"
status_is 1; reads_are 2
has out.txt "focus is in a different field than the one at 500,1550"
verdict

dev_case clear-other-id
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field search true 100,900,900,1000)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a focused field with another id is another field"
status_is 1
has out.txt "focus is in a different field (com.example:id/search)"
verdict

# The node a keyboard moves keeps its id; one that arrives without the id the
# field had is another field, whatever its shape.
dev_case clear-id-lost
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,900,900,1000 | sed 's/com.example:id\/email//')"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: a moved field that lost its id is another field"
status_is 1; reads_are 2
has out.txt "focus is in a different field than the one at 500,1550"
verdict

# Another field held focus before the tap: a tap that does not take would leave
# the keys to that field, so it is asked for before any key - and left alone.
dev_case clear-focus-stays
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field name true 100,300,900,400)"
screen "$case_dir/adb/dump-2.xml" "$(field email false 100,1500,900,1600 Mine)" "$(field name true 100,300,900,400)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus left in another field stops the step before any key"
status_is 1; reads_are 2; typed_is "old text"
has out.txt "focus is in a different field (com.example:id/name)"
lacks adb/log "keycombination"
verdict

dev_case clear-focus-moves
printf 'old text' > "$case_dir/adb/typed"
screen "$case_dir/adb/dump-1.xml" "$(field email false 100,1500,900,1600)" "$(field name true 100,300,900,400 Name)"
screen "$case_dir/adb/dump-2.xml" "$(field email true 100,1500,900,1600)" "$(field name false 100,300,900,400 Name)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_flow "$case_dir/flow.json"
begin "clearTextId: focus taken from another field costs one read more, and clears"
status_is 0; reads_are 3; typed_is ""
verdict

# iOS: the fake idb first in PATH, the simulator id where the engine keeps it.
ios_case(){ new_case "$1"; mkdir -p "$case_dir/idb" "$case_dir/res" "$case_dir/tmp"
  printf 'FAKE-UDID' > "$case_dir/tmp/yukti-udid"; }
# tree <file> <element>... - an idb describe-all answer.
tree(){ local f="$1" e sep=""; shift
  { printf '['; for e in "$@"; do printf '%s%s' "$sep" "$e"; sep=","; done; printf ']\n'; } > "$f"; }
# itext <id> <y> [value] - a text field 300 wide and 40 high at x 40.
itext(){ printf '{"type":"TextField","role_description":"text field","AXUniqueId":"%s","AXLabel":"","AXValue":%s,"frame":{"x":40,"y":%s,"width":300,"height":40}}' \
  "$1" "${3:-\"@TYPED@\"}" "$2"; }
run_ios(){ local f="$1"; shift
  env -u YUKTI_VARIANT -u YUKTI_CONFIG PATH="$ROOT/tests/fake-sdk/idb-bin:$PATH" YUKTI_PLATFORM=ios FAKE_IDB_DIR="$case_dir/idb" \
    YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" "$@" \
    "$YUKTI" flow "$f" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }
ireads_are(){ local got; got="$(cat "$case_dir/idb/describes" 2>/dev/null || echo 0)"
  [ "$got" = "$1" ] || no "the screen was read $got times, wanted $1"; }
ityped_is(){ [ "$(cat "$case_dir/idb/typed" 2>/dev/null)" = "$1" ] || no "the field holds '$(cat "$case_dir/idb/typed" 2>/dev/null)', wanted '$1'"; }
bursts_are(){ local got; got="$(grep -c '^ui text ' "$case_dir/idb/log" 2>/dev/null)"
  [ "$got" = "$1" ] || no "$got calls to type, wanted $1"; }

ios_case ios-type
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a key at a time, the fields read once before and once after"
status_is 0; ireads_are 2; bursts_are 22; ityped_is "$VALUE"
verdict

ios_case ios-type-retry
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
printf '1' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a lost character is deleted back out and the value typed again"
status_is 0; ityped_is "$VALUE"; bursts_are 44
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-type-fails
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
printf '' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a field that keeps losing characters fails with counts, not the value"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
lacks out.txt "$VALUE"
verdict

ios_case ios-type-unchanged
tree "$case_dir/idb/desc-1.json" "$(itext email 200 "\"$VALUE\"")"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a field that already held the value is not where the keys went"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
verdict

# Between the two reads the layout moved up - the keyboard, or a scroll to the
# caret - and a field of the same shape above holds text of its own. The field
# typed into is the one in the same place in the column, not the neighbour.
ios_case ios-type-shifted
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
tree "$case_dir/idb/desc-2.json" "$(itext name 50 '"Ada"')" "$(itext email 150)"
printf '1' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a layout that moved between the reads still finds the field"
status_is 0; ityped_is "$VALUE"
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-type-shifted-lost
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')" "$(itext email 200)"
tree "$case_dir/idb/desc-2.json" "$(itext name 50 '"Ada"')" "$(itext email 150)"
printf '' > "$case_dir/idb/lossy"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a moved neighbour's own text is not counted as arrived"
status_is 1; has out.txt "arrived 0 of 22 characters after 3 attempts"
verdict

ios_case ios-type-secure
tree "$case_dir/idb/desc-1.json" "$(itext pin 200 '"@DOTS@"')"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a secure field is compared as dots"
status_is 0; ireads_are 2; ityped_is "$VALUE"
lacks out.txt "lost characters"
verdict

ios_case ios-type-placeholder
printf 'Email' > "$case_dir/idb/hint"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a placeholder the value replaced is not text of the field's own"
status_is 0; ireads_are 2; ityped_is "$VALUE"
lacks out.txt "lost characters"
verdict

ios_case ios-type-placeholder-lost
printf 'Email' > "$case_dir/idb/hint"; printf '1' > "$case_dir/idb/lossy"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_VALUE}" }'
run_ios "$case_dir/flow.json" TEST_VALUE="$VALUE"
begin "type on iOS: a key lost in a field with a placeholder is typed again"
status_is 0; ityped_is "$VALUE"
has out.txt "22 characters arrived on attempt 2"
verdict

ios_case ios-clear
printf 'old text' > "$case_dir/idb/typed"
tree "$case_dir/idb/desc-1.json" "$(itext email 200)"
flow_file "$case_dir/flow.json" '{ "do": "clearTextId", "value": "email" }'
run_ios "$case_dir/flow.json"
begin "clearTextId on iOS: one read finds the field, one proves it empty"
status_is 0; ireads_are 2; ityped_is ""
has out.txt "field empty at 190,220"
verdict

# ── the resident screen helper (#105) ────────────────────────────────────────
# The helper is tests/fake-sdk/uia2-server, one per case on a free port, and
# the fake adb forwards to it. The cache starts with the pinned pair already
# marked as installed on the fake device, so a case downloads and installs
# nothing unless it means to - the fake APKs could never match the real sha.
SERVER_SHA="$(sed -n 's/^UIA2_SERVER_SHA="\(.*\)"$/\1/p' "$YUKTI")"
TEST_SHA="$(sed -n 's/^UIA2_TEST_SHA="\(.*\)"$/\1/p' "$YUKTI")"
SERVER_APK="$(sed -n 's/^UIA2_VER="\(.*\)"$/appium-uiautomator2-server-\1.apk/p' "$YUKTI")"
CACHE_SUB="$(sed -n 's/^UIA2_VER="\(.*\)"$/yukti\/uia2-\1/p' "$YUKTI")"
CACHE="cache/$CACHE_SUB"
server_pid=""
helper_case(){ dev_case "$1"; mkdir -p "$case_dir/$CACHE" "$case_dir/bin"
  printf '%s %s' "$SERVER_SHA" "$TEST_SHA" > "$case_dir/$CACHE/installed-emulator-5554"
  : > "$case_dir/adb/installed"
  /usr/bin/python3 "$ROOT/tests/fake-sdk/uia2-server" "$case_dir/adb" & server_pid=$!
  local i; for i in $(seq 1 50); do [ -s "$case_dir/adb/server-port" ] && break; sleep 0.1; done; }
# Remove one file of the case. The guard keeps an empty case_dir from turning
# the path into one at the root.
gone(){ rm -f "${case_dir:?}/$1"; }
# Stop what a case left running: the fake server, and a fake `am instrument`
# that waits for the helper to be stopped.
helper_done(){ gone adb/running; [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=""; }
# helper_screen <file> <element>... - the tree as the helper writes it:
# indented, one element per line, each named by its class.
helper_screen(){ local f="$1" n; shift
  { printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\r\n"
    printf '<hierarchy index="0" class="hierarchy" rotation="0" width="1080" height="2400">\r\n'
    printf '  <android.widget.FrameLayout index="0" package="com.example" class="android.widget.FrameLayout" text="" resource-id="" bounds="[0,0][1080,2400]" displayed="true">\r\n'
    for n in "$@"; do printf '    %s\r\n' "$n"; done
    printf '  </android.widget.FrameLayout>\r\n</hierarchy>'; } > "$f"; }
# hnode <class> <resource-id> <text> - one element as the helper writes it: no
# content-desc when it is empty, attributes of its own the dump does not have.
hnode(){ printf '<android.widget.%s index="0" package="com.example" class="android.widget.%s" text="%s" resource-id="com.example:id/%s" clickable="true" enabled="true" focusable="true" focused="false" password="false" bounds="[0,%d][1080,%d]" displayed="true" />' \
  "$1" "$1" "$3" "$2" "$(node_y "$2")" "$(( $(node_y "$2") + 120 ))"; }
# run_helper <yukti args...> [-- VAR=value...] - like run_flow, with the helper
# allowed and the case's own cache and PATH.
run_helper(){ local a=() e=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do a+=("$1"); shift; done
  [ $# -gt 0 ] && { shift; e=("$@"); }
  env -u ANDROID_SDK_ROOT -u YUKTI_HELPER -u YUKTI_HELPER_KEEP -u ANDROID_SERIAL \
    ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_PLATFORM=android PATH="$case_dir/bin:$PATH" \
    FAKE_ADB_DIR="$case_dir/adb" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" \
    XDG_CACHE_HOME="$case_dir/cache" ${e[@]+"${e[@]}"} "$YUKTI" "${a[@]}" > "$case_dir/out" 2>&1
  run_status=$?
  sed $'s/\033\\[[0-9;]*m//g' "$case_dir/out" > "$case_dir/out.txt"; }
count_is(){ local n; n="$(grep -cF -- "$2" "$case_dir/$1" 2>/dev/null)"; [ "${n:-0}" -eq "$3" ] || no "$1 has \"$2\" ${n:-0} times, wanted $3"; }
is_there(){ [ -e "$case_dir/$1" ] || no "$1 is missing"; }
value_is(){ [ "$(cat "$case_dir/$1" 2>/dev/null)" = "$2" ] || no "$1 is '$(cat "$case_dir/$1" 2>/dev/null)', wanted '$2'"; }

helper_case helper-reads
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "tapId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a live helper answers every read, no dump at all"
status_is 0; fake_used; file_absent adb/dumps
has adb/settings '"waitForIdleTimeout":500'; count_is adb/http-log "/source" 2
lacks adb/log "am instrument"; lacks adb/log "force-stop"
has out.txt "· read helper"; has out.txt "screen reads: 2 by the helper, 0 by uiautomator dump, 0 fallback(s)"
verdict; helper_done

helper_case helper-start-fails
: > "$case_dir/adb/start-fails"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a start that fails is tried once, then the run dumps"
status_is 0; count_is adb/log "am instrument" 1; count_is adb/log "force-stop" 1; value_is adb/dumps 2
count_is out.txt "screen helper: it did not come up" 1
value_is "$CACHE/start-fail-emulator-5554" 1
verdict; helper_done

helper_case helper-nonxml
: > "$case_dir/adb/running"; echo nonxml > "$case_dir/adb/source-mode"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: three answers in a row that are not a tree stop it, and the run dumps"
status_is 0; value_is adb/sources 3; count_is adb/log "force-stop" 1; value_is adb/dumps 2
has out.txt "three reads in a row gave no tree"; has out.txt "1 fallback(s)"
verdict; helper_done

helper_case helper-nonxml-once
: > "$case_dir/adb/running"; echo nonxml-once > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: one answer that is not a tree is read again, not given up on"
status_is 0; value_is adb/sources 2; file_absent adb/dumps; lacks adb/log "force-stop"
verdict; helper_done

helper_case helper-off
gone "$CACHE/installed-emulator-5554"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: YUKTI_HELPER=0 never asks the helper and never touches the cache"
status_is 0; value_is adb/dumps 1; file_absent adb/http-log
[ -z "$(ls -A "$case_dir/$CACHE")" ] || no "the cache was written: $(ls -A "$case_dir/$CACHE")"
lacks adb/log "forward"; lacks adb/log "get-serialno"; lacks adb/log "pidof"
verdict; helper_done

helper_case helper-sha-mismatch
gone adb/installed; gone "$CACHE/installed-emulator-5554"
printf 'not the release' > "$case_dir/adb/download-$SERVER_APK"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a download that does not match the pinned sha is thrown away, nothing installed"
status_is 0; has adb/log "curl https://github.com/appium/appium-uiautomator2-server/releases/download/"
lacks adb/log "install -r -g"; lacks adb/log "am instrument"
file_absent "$CACHE/$SERVER_APK"; [ -z "$(ls -A "$case_dir/$CACHE" | grep download)" ] || no "a partial download was left in the cache"
count_is out.txt "did not match the pinned sha256" 1; value_is adb/dumps 2
file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-no-forward
gone adb/server-port
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }' '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a flow that gets no forward from adb says so, and counts it as a fallback"
status_is 0; has adb/log "forward tcp:0 tcp:6790"; lacks adb/log "am instrument"; value_is adb/dumps 2
count_is out.txt "screen helper: adb could not forward a port to it" 1
has out.txt "screen reads: 0 by the helper, 2 by uiautomator dump, 1 fallback(s)"
verdict; helper_done

helper_case helper-stale-session
: > "$case_dir/adb/running"; printf 'stale' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: a kept session that expired is opened again, and the wait set after it"
status_is 0; file_absent adb/dumps; value_is adb/sessions 1; has adb/settings '"waitForIdleTimeout":500'
has adb/http-log "GET /session/stale/source"; value_is "$CACHE/session-emulator-5554" s1
verdict; helper_done

helper_case helper-forward-lost
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
gone adb/forward; : > "$case_dir/adb/log"
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: a forward lost with adbd is made again; nothing is installed or started"
status_is 0; file_absent adb/dumps; has adb/log "forward tcp:0 tcp:6790"
lacks adb/log "install"; lacks adb/log "am instrument"; value_is adb/sessions 1
verdict; helper_done

helper_case helper-stop
: > "$case_dir/adb/running"; echo 4321 > "$case_dir/adb/forward"
printf 's9' > "$case_dir/$CACHE/session-emulator-5554"; echo 2 > "$case_dir/$CACHE/start-fail-emulator-5554"
run_helper helper stop
begin "helper: 'yukti helper stop' stops it, removes the forward and forgets the kept state"
status_is 0; has adb/log "force-stop"; has adb/log "forward --remove tcp:4321"
file_absent adb/running; file_absent adb/forward
file_absent "$CACHE/session-emulator-5554"; file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-start-twice
: > "$case_dir/adb/start-fails"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"; run_helper flow "$case_dir/flow.json"; run_helper flow "$case_dir/flow.json"
begin "helper: after two failed starts in a row the device is not tried again"
status_is 0; count_is adb/log "am instrument" 2; value_is "$CACHE/start-fail-emulator-5554" 2
has out.txt "failed to start twice in a row"
verdict; helper_done

helper_case helper-holds-dump
: > "$case_dir/adb/foreign"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: a dump killed by somebody's helper says so"
status_is 1; has out.txt "is running on the device and takes every dump down"; has out.txt "yukti helper stop"
verdict; helper_done

helper_case helper-no-dump
printf 'garbage' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER=0
begin "helper: with no helper on the device an empty dump keeps its old message"
status_is 1; has out.txt "the screen may still be animating"; lacks out.txt "takes every dump down"
verdict; helper_done

helper_case helper-other-sha
printf 'old old' > "$case_dir/$CACHE/installed-emulator-5554"
printf 'tampered' > "$case_dir/$CACHE/$SERVER_APK"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: another pair on the device means a reinstall, and the cached APK is checked first"
status_is 0; lacks adb/log "install -r -g"; file_absent "$CACHE/$SERVER_APK"
has adb/log "curl "; has out.txt "did not match the pinned sha256"
verdict; helper_done

helper_case helper-tags
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" \
  '<android.widget.FrameLayout index="0" package="com.example" class="android.widget.FrameLayout" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  '<com.facebook.react.views.view.ReactViewGroup index="0" package="com.example" class="com.facebook.react.views.view.ReactViewGroup" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  '<com.example.Outer$Inner index="0" package="com.example" class="com.example.Outer$Inner" text="" resource-id="" bounds="[0,100][1080,2400]">' \
  "$(hnode TextView deep "$MARK")" '</com.example.Outer$Inner>' '</com.facebook.react.views.view.ReactViewGroup>' '</android.widget.FrameLayout>'
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "deep" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "helper: every tag but the root becomes <node>, open, closing and empty"
status_is 1; has out.txt "not on screen"; file_full res/flow-fail.xml; has res/flow-fail.xml "$MARK"
lacks res/flow-fail.xml "<android."; lacks res/flow-fail.xml "</android."; lacks res/flow-fail.xml "<com."; lacks res/flow-fail.xml "</com."
has res/flow-fail.xml "<hierarchy"; has res/flow-fail.xml "</hierarchy>"
verdict; helper_done

helper_case helper-ui-kept
: > "$case_dir/adb/running"; printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"
printf 's1' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' reads through a kept helper whose forward was lost, and leaves it up"
status_is 0; has out "com.example:id/title"; file_absent adb/dumps; has adb/log "forward tcp:0 tcp:6790"
is_there adb/running; lacks adb/log "force-stop"; lacks adb/log "am instrument"
verdict; helper_done

helper_case helper-ui-forward-kept
: > "$case_dir/adb/running"; printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"
printf 's1' > "$case_dir/$CACHE/session-emulator-5554"; cp "$case_dir/adb/server-port" "$case_dir/adb/forward"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' reads through a kept helper and its forward, checked once"
status_is 0; has out "com.example:id/title"; file_absent adb/dumps
lacks adb/log "forward tcp:0"; count_is adb/http-log "/status" 1; is_there adb/running
verdict; helper_done

helper_case helper-ui-none
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
run_helper ui
begin "helper: 'yukti ui' with no helper dumps, and starts nothing"
status_is 0; has out "com.example:id/title"; value_is adb/dumps 1
lacks adb/log "am instrument"; lacks adb/log "forward tcp:0"; lacks out.txt "screen helper:"
verdict; helper_done

helper_case helper-own-stop
printf '#!/bin/sh\necho "setsid $*" >> "%s/adb/log"; exit 1\n' "$case_dir" > "$case_dir/bin/setsid"; chmod +x "$case_dir/bin/setsid"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a flow starts it without setsid(1) and stops it on the way out"
status_is 0; file_absent adb/dumps; count_is adb/log "am instrument" 1; lacks adb/log "setsid"
has adb/log "force-stop"; file_absent adb/running; file_absent adb/forward
file_absent "$CACHE/start-fail-emulator-5554"
verdict; helper_done

helper_case helper-keep
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "helper: YUKTI_HELPER_KEEP=1 leaves it up with its session for the next run"
status_is 0; count_is adb/log "am instrument" 1; lacks adb/log "force-stop"
is_there adb/running; value_is "$CACHE/session-emulator-5554" s1
verdict; run_helper helper stop; helper_done

helper_case helper-slow
: > "$case_dir/adb/running"; echo slow > "$case_dir/adb/source-mode"
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_TIMEOUT=1
begin "helper: a read that times out is a failed try; three of them and the run dumps"
status_is 0; value_is adb/sources 3; value_is adb/dumps 1; has out.txt "three reads in a row gave no tree"
[ "$(sed -n '/source/,$p' "$case_dir/adb/http-log" | grep -c /status)" -eq 0 ] || no "/status was asked after a timeout"
verdict; helper_done

helper_case helper-died
: > "$case_dir/adb/running"; echo die > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hnode TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "assertId", "value": "title" }'
run_helper flow "$case_dir/flow.json"
begin "helper: a helper that died mid-run is started again, once"
status_is 0; file_absent adb/dumps; count_is adb/log "am instrument" 1; value_is adb/sessions 2
verdict; helper_done

# ── searching a list: the helper's gesture and the time limit (#107) ──────────
# A list from y 200 to 2200 on the fake 1080x2400 screen, rows 200 apart with
# their centres at 300, 500 ... 2100. The anchors the search picks there:
#   a screen at a time (80%): the row at 1900, 85% of the way, to 300
#   two fifths (40%):         the row at 1500, 65% of the way, to 700
# hlist / dlist <prefix> [target-label target-centre] - one such list as the
# helper writes it / as a dump does, its rows named "<prefix> 1".."<prefix> 10";
# a target replaces the row whose centre it takes.
# A prefix @n is a window on one long list instead: rows "R n".."R n+9", so two
# windows share the rows a swipe leaves on the screen, as a real list does. The
# screen-long swipe moves it by 8 rows, two fifths by 4 (#117).
lrows(){ local fmt="$1" p="$2" t="${3:-}" ty="${4:-0}" k y lab
  for k in 1 2 3 4 5 6 7 8 9 10; do y=$(( 100 + k * 200 )); lab="$p $k"
    case "$p" in @*) lab="R $(( ${p#@} + k - 1 ))";; esac
    [ "$y" = "$ty" ] && lab="$t"
    printf "$fmt" "$lab" $(( y - 50 )) $(( y + 50 )); done; }
hlist(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  lrows '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="true" />' "$@"
  printf '</android.widget.ScrollView>'; }
dlist(){ printf '<node index="0" text="" resource-id="com.example:id/list" class="android.widget.ScrollView" package="com.example" content-desc="" scrollable="true" bounds="[0,200][1080,2200]">'
  lrows '<node index="0" text="%s" resource-id="" class="android.widget.TextView" package="com.example" content-desc="" scrollable="false" bounds="[40,%d][1040,%d]" />' "$@"
  printf '</node>'; }
# The gestures the helper was sent, one JSON line each.
gestures_are(){ local n; n="$(wc -l < "$case_dir/adb/actions" 2>/dev/null || echo 0)"
  [ "${n// /}" -eq "$1" ] || no "the helper was sent ${n// /} gestures, wanted $1"; }
# gesture_line <n> <x1> <y1> <x2> <y2> - the n-th gesture went from one point to
# the other, stopped, and lifted at speed zero: a 20 ms move to the same point.
gesture_line(){ "$PY3" - "$case_dir/adb/actions" "$@" <<'PY' || no "gesture $1 is not $2,$3 -> $4,$5 with a stop before the lift"
import json, sys
f, n, x1, y1, x2, y2 = sys.argv[1], int(sys.argv[2]), *map(int, sys.argv[3:7])
g = json.loads(open(f).read().splitlines()[n - 1])["actions"][0]
a = g["actions"]
assert g["parameters"]["pointerType"] == "touch"
assert [s["type"] for s in a] == ["pointerMove", "pointerDown", "pointerMove", "pause", "pointerMove", "pointerUp"]
assert (a[0]["x"], a[0]["y"], a[0]["duration"]) == (x1, y1, 0)
assert (a[2]["x"], a[2]["y"]) == (x2, y2) and a[3]["duration"] >= 150
assert (a[4]["x"], a[4]["y"]) == (x2, y2) and a[4]["duration"] >= 20
PY
}
PY3=/usr/bin/python3

helper_case scroll-helper-far
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: with the helper a search swipes a screen at a time, with a finger that stops before it lifts"
status_is 0; file_absent adb/dumps; gestures_are 2; count_is adb/http-log "/actions" 2
gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
lacks adb/log "input swipe"; count_is out.txt "· swipe helper" 2; has out.txt "· search 2 swipes"
lacks out.txt "went past the gesture"
verdict; helper_done

helper_case scroll-helper-up
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @1 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "up" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: going up, the screen-long swipe runs the other way"
status_is 0; gestures_are 1; gesture_line 1 540 500 540 2100
verdict; helper_done

helper_case scroll-helper-clear
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1 Target 1900)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @5 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "edges": "clear" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: an element in view is brought into the band by two fifths, not flown past it"
status_is 0; gestures_are 1; gesture_line 1 540 1500 540 700
verdict; helper_done

helper_case scroll-helper-taptext
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "tapText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: tapText searches with the same gesture and taps through adb"
status_is 0; gestures_are 1; lacks adb/log "input swipe"; has adb/log "input tap 540 1100"
verdict; helper_done

helper_case scroll-helper-step
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
flow_file "$case_dir/flow.json" '{ "do": "scroll", "value": "down" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the scroll step keeps its own swipe through adb"
status_is 0; gestures_are 0; has adb/log "input swipe"
verdict; helper_done

# Known, and measured on a device rather than here: a read that catches the list
# before its rows are drawn sees no rows, and the search swipes on. On a device
# the rows it skipped may have held the element; here the next screen holds it.
helper_case scroll-helper-undrawn
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true" />'
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a list read before its rows are drawn is swiped past (known, see the comment)"
status_is 0; gestures_are 2; value_is adb/sources 3; count_is out.txt "· full tree" 1; lacks out.txt "went past the gesture"
verdict; helper_done

# A row of tiles 200 wide from x 8, centres at 108, 324 ... 972; the
# screen-long swipe starts on the last tile, 90% of the way, and goes 80%. A
# prefix @n is a window on one long row, tiles "T n".."T n+4"; the screen-long
# swipe moves it by 4 tiles.
htiles(){ local p="$1" t="${2:-}" k x lab
  printf '<android.widget.HorizontalScrollView index="0" package="com.example" class="android.widget.HorizontalScrollView" text="" resource-id="com.example:id/row" scrollable="true" bounds="[0,800][1080,1100]" displayed="true">'
  for k in 1 2 3 4 5; do x=$(( 8 + (k - 1) * 216 )); lab="$p $k"
    case "$p" in @*) lab="T $(( ${p#@} + k - 1 ))";; esac
    [ "$k" = 3 ] && [ -n "$t" ] && lab="$t"
    printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[%d,900][%d,1000]" displayed="true" />' "$lab" "$x" $(( x + 200 )); done
  printf '</android.widget.HorizontalScrollView>'; }
helper_case scroll-helper-right
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(htiles @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(htiles @5 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "right" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: sideways, the screen-long swipe runs along the row at its height"
status_is 0; gestures_are 1; gesture_line 1 942 950 78 950
verdict; helper_done

# ── the strips at the sides of the screen (#123) ──────────────────────────────
# On the fake 420 dpi screen a swipe starts 137 px or further from either side:
# 50 dp, where a stack screen takes the touch as the back gesture, and 2 more.
# The tile the screen-long swipe takes above is centred at 972, in the right
# strip, so the swipe starts at 942 on the same tile and keeps its length.
# elist @n <x1> <x2> [target] - the window of hlist on one long list, with the
# row the screen-long swipe takes (the 9th, centre 1900) drawn from x1 to x2
# only; a target takes the row centred at 1100.
elist(){ local n="${1#@}" a="$2" b="$3" t="${4:-}" k y lab l r
  printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  for k in 1 2 3 4 5 6 7 8 9 10; do y=$(( 100 + k * 200 )); lab="R $(( n + k - 1 ))"; l=40; r=1040
    [ "$k" = 9 ] && { l="$a"; r="$b"; }
    [ -n "$t" ] && [ "$y" = 1100 ] && lab="$t"
    printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[%d,%d][%d,%d]" displayed="true" />' "$lab" "$l" $(( y - 50 )) "$r" $(( y + 50 )); done
  printf '</android.widget.ScrollView>'; }

helper_case scroll-helper-edge-anchor
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 20 200)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @9 20 200)"
helper_screen "$case_dir/adb/helper-3.xml" "$(elist @17 20 200 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a line of text that reaches into the left strip is swiped from its part outside it; asking the density does not take the tree"
status_is 0; gestures_are 2; gesture_line 1 137 1900 137 300; gesture_line 2 137 1900 137 300
count_is adb/log "shell wm density" 1; lacks out.txt "density unavailable"
verdict; helper_done

helper_case scroll-helper-edge-skip
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 10 120)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @8 10 120 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a line of text all in the left strip is passed over for another one"
status_is 0; gestures_are 1; gesture_line 1 540 1700 540 300
verdict; helper_done

helper_case scroll-helper-edge-left
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(htiles @5)"
helper_screen "$case_dir/adb/helper-2.xml" "$(htiles @1 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "direction": "left" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: sideways to the left, the swipe does not start in the left strip and run as the back gesture"
status_is 0; gestures_are 1; gesture_line 1 137 950 1001 950
verdict; helper_done

helper_case scroll-helper-edge-no-density
: > "$case_dir/adb/running"; : > "$case_dir/adb/no-density"
helper_screen "$case_dir/adb/helper-1.xml" "$(elist @1 20 200)"
helper_screen "$case_dir/adb/helper-2.xml" "$(elist @9 20 200)"
helper_screen "$case_dir/adb/helper-3.xml" "$(elist @17 20 200 Target)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: without the density the strip is a seventh of the width, and the run says so once"
status_is 0; gestures_are 2; gesture_line 1 156 1900 156 300; gesture_line 2 156 1900 156 300
count_is out.txt "screen density unavailable, keeping swipes 156 px off the sides of the screen" 1
verdict; helper_done

dev_case scroll-dump
screen "$case_dir/adb/dump-1.xml" "$(dlist A)"
screen "$case_dir/adb/dump-2.xml" "$(dlist B)"
screen "$case_dir/adb/dump-3.xml" "$(dlist C Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_flow "$case_dir/flow.json"
begin "scroll: without the helper a search swipes two fifths through adb, as before"
status_is 0; count_is adb/log "input swipe 540 1500 540 700 600" 2; count_is out.txt "· swipe adb" 2
lacks out.txt "went past the gesture"
verdict

helper_case scroll-helper-gone
: > "$case_dir/adb/running"; echo gone > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
screen "$case_dir/adb/dump-1.xml" "$(dlist B)"
screen "$case_dir/adb/dump-2.xml" "$(dlist C Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a helper gone during a gesture is given up on, that line goes through adb at half the length, the rest of the step too"
status_is 0; gestures_are 1; has out.txt "it did not answer a swipe"
has adb/log "input swipe 540 1900 540 1100 600"; has adb/log "input swipe 540 1500 540 700 600"
has out.txt "· swipe adb"; has out.txt "(helper: rc 2)"
verdict; helper_done

# Two refusals leave the list where it was, so the second read looks like the
# end of the list: the search waits there for it to grow, and the control swipe
# of that wait - on adb by then - is what moves it.
helper_case scroll-helper-refuses
: > "$case_dir/adb/running"; echo fail > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist B Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a refused gesture is not repeated on adb, and after two refusals the run swipes through adb"
status_is 0; gestures_are 2; count_is out.txt "(helper: rc 5)" 2; count_is adb/log "input swipe" 1
has out.txt "· search 1 swipes"
file_absent adb/dumps
verdict; helper_done

helper_case scroll-helper-hang
: > "$case_dir/adb/running"; echo hang > "$case_dir/adb/actions-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist A)"
screen "$case_dir/adb/dump-1.xml" "$(dlist A)"
screen "$case_dir/adb/dump-2.xml" "$(dlist B Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_TIMEOUT=1
begin "scroll: a gesture with no answer in time is not swiped again, and the helper is given up on"
status_is 0; gestures_are 1; has out.txt "(helper: rc 4)"; has out.txt "it did not answer a swipe"
count_is adb/log "input swipe" 1
verdict; helper_done

helper_case scroll-budget
: > "$case_dir/adb/running"
for k in $(seq 1 80); do helper_screen "$case_dir/adb/helper-$k.xml" "$(hlist "@$(( 8 * k - 7 ))")"; done
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_SCROLL_BUDGET=2
begin "scroll: a list that keeps moving stops the search after its time, not after a count"
status_is 1; has out.txt "still moving after 2s of swiping down, 'Target' not found"
grep -q "· search [1-9][0-9]* swipes" "$case_dir/out.txt" || no "no search line with swipes"
verdict; helper_done

# ── a list that travels further than the finger (#117) ───────────────────────
# The screen-long swipe from window @1 leaves rows 9 and 10 on the screen - the
# seam. A read without them, with rows of its own, is a list that went past the
# gesture: the search goes back by two fifths until the seam is there again,
# and on from it by two fifths.
helper_case scroll-over-back
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a list that went past the gesture is swiped back to the seam, then on by two fifths"
status_is 0; gestures_are 3; count_is out.txt "went past the gesture - going back" 1
gesture_line 1 540 1900 540 300; gesture_line 2 540 700 540 1500; gesture_line 3 540 1500 540 700
verdict; helper_done

helper_case scroll-over-found-back
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @21 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: an element met on the way back is the answer"
status_is 0; gestures_are 2; gesture_line 2 540 700 540 1500
verdict; helper_done

# The way back checks the seam that was lost, not the seam of its own swipe: the
# read after the first swipe back has neither rows 9-10 nor the element, and the
# search goes back once more.
helper_case scroll-over-back-twice
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @21)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-5.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the way back goes on until the lost seam is on the screen again"
status_is 0; gestures_are 4
gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500; gesture_line 4 540 1500 540 700
verdict; helper_done

# Rows with no label give no seam, and nothing is judged.
hblank(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true">'
  lrows '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="" hint="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="true" />' X
  printf '</android.widget.ScrollView>'; }
helper_case scroll-over-no-seam
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hblank)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a swipe over rows with no label leaves no seam to check"
status_is 0; gestures_are 2; lacks out.txt "went past the gesture"
verdict; helper_done

# Back to the start of the list without the seam: forward again at once, with
# no wait for the start to grow: two swipes back, the control swipe at the start,
# and the fifth gesture is the forward one. The miss at the end is the usual one.
helper_case scroll-over-start
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @41)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @65)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @101)"
helper_screen "$case_dir/adb/helper-6.xml" "$(hlist @201)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "scroll: the way back that reaches the start turns forward at once"
status_is 1; has out.txt "reached the end of the list going down and it did not grow for 1s, 'Target' is not in it"
count_is out.txt "went past the gesture" 1
gesture_line 2 540 700 540 1500; gesture_line 3 540 700 540 1500; gesture_line 5 540 1500 540 700
verdict; helper_done

# One way back per step: a list that goes past again after it is said so, and
# the search goes on.
helper_case scroll-over-twice
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @41)"
helper_screen "$case_dir/adb/helper-5.xml" "$(hlist @45 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "scroll: a second overshoot in a step is said, not gone back for"
status_is 0; gestures_are 4; count_is out.txt "went past the gesture - going back" 1; count_is out.txt "went past the gesture" 2
gesture_line 4 540 1500 540 700
verdict; helper_done

# ── a row below the fold, and a swipe by the distance to it (#116) ──────────
# With allowInvisibleElements on, the helper keeps the rows below the fold, upside
# down: the top where the row stands in the content, the bottom pinned to the
# bottom of the list (2200). On the lists above the visible part is 200-2200 and
# the band 164-2306, so the top of the element is aimed at 1200, and the
# screen-long line, 1900 to 300, is the longest a distance swipe goes.
# below <label:top> - one such row; inlist <list> <element>... - the list with
# more elements inside it; hfull <list> <label:top>... - with rows below the fold.
below(){ printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,2200]" displayed="false" />' "${1%:*}" "${1##*:}"; }
inlist(){ local l="$1"; shift; printf '%s' "${l%</android.widget.ScrollView>}" "$@" '</android.widget.ScrollView>'; }
hfull(){ local l="$1" b r=""; shift; for b in "$@"; do r="$r$(below "$b")"; done; inlist "$l" "$r"; }
# full_reads_are <n> - n full reads, each the setting on, one source, the
# setting off, with no other request in between: no plain read sees the rows
# below the fold.
full_reads_are(){ "$PY3" - "$case_dir/adb/http-log" "$1" <<'PY' || no "http-log does not hold $1 full read(s) of: setting on, one source, setting off"
import sys
lines, n, got, i = open(sys.argv[1]).read().splitlines(), int(sys.argv[2]), 0, 0
while i < len(lines):
    if '"allowInvisibleElements":true' in lines[i]:
        assert lines[i + 1].startswith("GET ") and lines[i + 1].endswith("/source")
        assert '"allowInvisibleElements":false' in lines[i + 2]
        got += 1; i += 3; continue
    assert "allowInvisibleElements" not in lines[i]
    i += 1
assert got == n
PY
}

helper_case scroll-dist
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element below the fold is swiped to by its distance, one swipe, and found by a plain read"
status_is 0; gestures_are 1; gesture_line 1 540 1900 540 650; full_reads_are 1
count_is out.txt "· full tree" 1; has out.txt "· search 1 swipes"; value_is adb/sources 2
lacks out.txt "went past the gesture"
verdict; helper_done

# The list went 0.8 of the first swipe: 3500 to 2220 on 1600. The second swipe
# is the distance left divided by it, 1020 / 0.8.
helper_case scroll-dist-ratio
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3500)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" Target:2220)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @15 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the share the element travelled on one swipe sets the length of the next"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 625
full_reads_are 2; lacks out.txt "distance scroll ratio"
verdict; helper_done

helper_case scroll-dist-over
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @25)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @5)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a list that went past a distance swipe is said so and swiped back, as after any (#117)"
status_is 0; gestures_are 3; count_is out.txt "went past the gesture - going back (distance)" 1
gesture_line 1 540 1900 540 650; gesture_line 2 540 700 540 1500; gesture_line 3 540 1500 540 700
count_is out.txt "· full tree" 1
verdict; helper_done

helper_case scroll-dist-still
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @3 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a distance swipe that moved nothing ends it, and the control swipe follows"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 650; gesture_line 2 540 1300 540 800
count_is out.txt "· full tree" 1
verdict; helper_done

# Content above the element grew between the reads: its top went down, 3500 to
# 3600, and that share is no list moving.
helper_case scroll-dist-grew
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3500)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" Target:3600)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a share outside 0.5-1.5 is said and taken as 1"
status_is 0; gestures_are 2; count_is out.txt "· distance scroll ratio -0.06 out of range - using 1" 1
gesture_line 2 540 1900 540 300
verdict; helper_done

# No row on the screen - a list read before its rows are drawn, a canvas: same_rows
# has nothing to tell the list still by, the top of the element has. The swipe
# starts on the grid, 88% of the way.
hempty(){ printf '<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,2200]" displayed="true"></android.widget.ScrollView>'; }
helper_case scroll-dist-unlabelled
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hempty)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hempty)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hempty)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hempty)" Target:2450)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: on a list with no row on the screen, a top that did not move ends it"
status_is 0; gestures_are 2; gesture_line 1 540 1960 540 710; gesture_line 2 540 1960 540 360
count_is out.txt "· full tree" 2
verdict; helper_done

# A short list, 200-640, and the band cleared of its edges, 592-1878: the top
# is aimed at 616, and an element whose top is at 650 is 34 px away - no swipe
# is that short. The usual line goes out: the row at 500, 63% of the way.
SHORT_LIST='<android.widget.ScrollView index="0" package="com.example" class="android.widget.ScrollView" text="" resource-id="com.example:id/list" scrollable="true" bounds="[0,200][1080,640]" displayed="true">'
srow(){ printf '<android.widget.TextView index="0" package="com.example" class="android.widget.TextView" text="%s" resource-id="" scrollable="false" bounds="[40,%d][1040,%d]" displayed="%s" />' "$@"; }
helper_case scroll-dist-short
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$SHORT_LIST$(srow 'A 1' 250 350 true)$(srow 'A 2' 450 550 true)</android.widget.ScrollView>"
helper_screen "$case_dir/adb/helper-full-1.xml" "$SHORT_LIST$(srow 'A 1' 250 350 true)$(srow 'A 2' 450 550 true)$(srow Target 650 640 false)</android.widget.ScrollView>"
helper_screen "$case_dir/adb/helper-2.xml" "$SHORT_LIST$(srow 'A 3' 250 350 true)$(srow Target 590 640 true)</android.widget.ScrollView>"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "edges": "clear" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element nearer than a swipe can go gets the usual line"
status_is 0; gestures_are 1; gesture_line 1 540 500 540 223; count_is out.txt "· full tree" 1
verdict; helper_done

# A slider over the row the screen-long line starts on: the distance swipe
# starts on the next line of text, the row at 1700, as any line would.
SLIDER='<android.widget.SeekBar index="0" package="com.example" class="android.widget.SeekBar" text="" resource-id="com.example:id/slider" scrollable="false" bounds="[0,1850][1080,1950]" displayed="true" />'
helper_case scroll-dist-finger
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(inlist "$(hlist @1)" "$SLIDER")"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(inlist "$(hlist @1)" "$SLIDER")" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the finger goes down on text, not on a slider"
status_is 0; gestures_are 1; gesture_line 1 540 1700 540 450
verdict; helper_done

# Not in the full tree: the search swipes to the lowest row below the fold by
# its distance, then goes on as it always did.
helper_case scroll-dist-end-grows
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:3050')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: not in the full tree - to the lowest row below the fold, then the usual search finds rows drawn later"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
count_is out.txt "· full tree" 2; lacks out.txt "lost the target"
verdict; helper_done

helper_case scroll-dist-end
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:3050')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hlist @9)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target", "timeout": 1 }'
run_helper flow "$case_dir/flow.json"
begin "distance: not in the full tree and the list ends - the usual miss, after the usual wait"
status_is 1; has out.txt "reached the end of the list going down and it did not grow for 1s, 'Target' is not in it"
count_is out.txt "· full tree" 2
verdict; helper_done

# The lowest row below the fold is another one after the swipe - a list that
# draws rows past its edge as it goes: 2900, then 2700 of another row. A share
# taken across two rows would be 0.12 and said; it is not taken.
helper_case scroll-dist-end-moves
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" 'R 11:2250' 'R 15:2900')"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @9)" 'R 19:2300' 'R 22:2700')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @16)"
helper_screen "$case_dir/adb/helper-full-3.xml" "$(hlist @16)"
helper_screen "$case_dir/adb/helper-4.xml" "$(hlist @24 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: to the end, each swipe goes by the lowest row of its own read, no share between two rows"
status_is 0; gestures_are 3; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 400
gesture_line 3 540 1900 540 300; lacks out.txt "distance scroll ratio"; count_is out.txt "· full tree" 3
verdict; helper_done

helper_case scroll-dist-lost
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7)"
helper_screen "$case_dir/adb/helper-full-2.xml" "$(hfull "$(hlist @7)" 'R 17:2300')"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @15 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element neither on the screen nor below the fold any more is said lost, and the usual search goes on"
status_is 0; count_is out.txt "· distance scroll lost the target" 1; gestures_are 2
gesture_line 1 540 1900 540 650; gesture_line 2 540 1900 540 300
verdict; helper_done

# A lazy list holds no row below the fold: the full read changes nothing.
helper_case scroll-dist-lazy
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @17 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: no rows below the fold - one full read, then the search as before"
status_is 0; gestures_are 2; gesture_line 1 540 1900 540 300; gesture_line 2 540 1900 540 300
full_reads_are 1; lacks out.txt "distance"
verdict; helper_done

helper_case scroll-dist-nonxml
: > "$case_dir/adb/running"; echo nonxml-full > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a full read that is not a tree switches the setting off, and the search goes on as before"
status_is 0; has out.txt "· full tree not read (helper: rc 5)"; full_reads_are 1
gestures_are 1; gesture_line 1 540 1900 540 300; value_is adb/sessions 1; file_absent adb/dumps
verdict; helper_done

helper_case scroll-dist-died
: > "$case_dir/adb/running"; echo die-full > "$case_dir/adb/source-mode"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: a helper that died on the full read is started again, once, and the swipe is its"
status_is 0; has out.txt "· full tree not read (helper: rc 2)"; count_is adb/log "am instrument" 1
value_is adb/sessions 2; gestures_are 1; lacks adb/log "input swipe"; file_absent adb/dumps
verdict; helper_done

# The setting not taken back: the session is forgotten in the run and in the
# cache - with either left, the next read would go on it, the setting still on
# - and a new one opened, with the wait and without the setting.
helper_case scroll-dist-stuck
: > "$case_dir/adb/running"; echo fail-false > "$case_dir/adb/settings-mode"
printf 's1' > "$case_dir/adb/session"; printf '1' > "$case_dir/adb/sessions"; printf 's1' > "$case_dir/$CACHE/session-emulator-5554"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_HELPER_KEEP=1
begin "distance: a session that did not take the setting back is dropped, here and in the cache, and opened anew"
status_is 0; value_is adb/sessions 2; value_is "$CACHE/session-emulator-5554" s2
has adb/settings '"waitForIdleTimeout":500'; lacks adb/settings "allowInvisibleElements"
gestures_are 1; gesture_line 1 540 1900 540 650; lacks adb/log "input swipe"
has adb/http-log "GET /session/s2/source"
verdict; helper_done

# In the full tree on the screen, in the plain read not there: nothing to swipe
# to by distance, and the line says so - not the same as no rows below the fold.
helper_case scroll-dist-on-full
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hlist @1 Target 1100)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @9 Target 1100)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element on the screen in the full tree only is said, and the search goes on as before"
status_is 0; count_is out.txt "· distance scroll: the full tree has the element on the screen" 1
gestures_are 1; gesture_line 1 540 1900 540 300
verdict; helper_done

helper_case scroll-dist-two
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:3000 Target:2450)"
helper_screen "$case_dir/adb/helper-2.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: of two equal matches below the fold, the nearer one"
status_is 0; gestures_are 1; gesture_line 1 540 1900 540 650
verdict; helper_done

helper_case scroll-dist-shown
: > "$case_dir/adb/running"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1 Target 1100)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1 Target 1100)" Target:2450)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: an element on the screen needs no full read, whatever lies below"
status_is 0; gestures_are 0; full_reads_are 0; lacks out.txt "full tree"
verdict; helper_done

helper_case scroll-dist-budget
: > "$case_dir/adb/running"
for k in $(seq 1 80); do
  helper_screen "$case_dir/adb/helper-$k.xml" "$(hlist "@$(( 8 * k - 7 ))")"
  helper_screen "$case_dir/adb/helper-full-$k.xml" "$(hfull "$(hlist "@$(( 8 * k - 7 ))")" "Z $k:3900")"
done
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json" -- YUKTI_SCROLL_BUDGET=2
begin "distance: swipes by distance are within the time of the search, and its miss is the usual one"
status_is 1; has out.txt "still moving after 2s of swiping down, 'Target' not found"
[ "$(grep -c '· full tree' "$case_dir/out.txt")" -ge 2 ] || no "fewer than two full reads"
verdict; helper_done

# The keyboard is closed first, and the screen read again: the full read comes
# after that read, not before it.
helper_case scroll-dist-keyboard
: > "$case_dir/adb/running"; : > "$case_dir/adb/keyboard"
helper_screen "$case_dir/adb/helper-1.xml" "$(hlist @1)"
helper_screen "$case_dir/adb/helper-full-1.xml" "$(hfull "$(hlist @1)" Target:2450)"
helper_screen "$case_dir/adb/helper-3.xml" "$(hlist @7 Target 1300)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_helper flow "$case_dir/flow.json"
begin "distance: the full read comes after the keyboard is closed"
status_is 0; has out.txt "keyboard closed"; gestures_are 1; full_reads_are 1
[ "$(awk '/allowInvisibleElements":true/ {print n; exit} /source$/ {n++}' "$case_dir/adb/http-log")" = 2 ] \
  || no "the full read did not come after the second plain read"
verdict; helper_done

dev_case scroll-blind
screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_flow "$case_dir/flow.json"
begin "scroll: a screen with no list still gets eight swipes down the middle"
status_is 1; has out.txt "searched 8 swipes down"; count_is adb/log "input swipe" 8; has out.txt "· search 8 swipes"
verdict

ios_case scroll-ios
tree "$case_dir/idb/desc-1.json" '{"type":"ScrollView","role_description":"scroll view","AXLabel":"","frame":{"x":0,"y":100,"width":402,"height":700}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Row 1","frame":{"x":20,"y":200,"width":300,"height":40}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Row 2","frame":{"x":20,"y":600,"width":300,"height":40}}'
tree "$case_dir/idb/desc-2.json" '{"type":"ScrollView","role_description":"scroll view","AXLabel":"","frame":{"x":0,"y":100,"width":402,"height":700}}' \
  '{"type":"StaticText","role_description":"text","AXLabel":"Target","frame":{"x":20,"y":400,"width":300,"height":40}}'
flow_file "$case_dir/flow.json" '{ "do": "scrollToText", "value": "Target" }'
run_ios "$case_dir/flow.json"
begin "scroll: on iOS a search keeps the idb swipe of two fifths"
status_is 0; count_is idb/log "ui swipe" 1; has out.txt "· swipe idb"; lacks out.txt "went past the gesture"
verdict

# ── an element at zero size, and a wait that may end without it (#111, #112) ─
# The root node comes first: the engine takes the first bounds of a dump as the
# screen. The button is the case these were made for - in the tree, at a point.
ROOT_NODE='<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" bounds="[0,0][1080,2400]" />'
ZERO_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[174,60][174,60]" />'
SIZED_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[100,40][250,90]" />'
BELOW_BTN='<node index="0" text="" resource-id="com.example:id/btn" class="android.view.ViewGroup" package="com.example" content-desc="Ask" clickable="true" bounds="[100,2500][250,2550]" />'
# A guarded step that leaves a trace when it runs: a wait of nothing, titled.
RAN='{ "do": "wait", "value": "0", "title": "guarded step", "when": { "zeroSizeId": "btn" } }'

dev_case zero-wait-names-zero
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on a zero-size element says so, with its corners"
status_is 1; fake_used
has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60]"
has res/flow.xml "at zero size [174,60][174,60]"; red_is failure StepFailed 1 0
verdict

dev_case zero-wait-names-missing
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on an id that is not in the tree says so"
status_is 1; fake_used; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

dev_case zero-wait-names-outside
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$BELOW_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a timeout on an element below the screen says so"
status_is 1; fake_used; has out.txt "'btn' not on screen after 1s - outside the screen at [100,2500][250,2550]"
verdict

dev_case zero-wait-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: a screen that cannot be read is not called any of the three"
status_is 1; fake_used; red_is error DeviceError 0 1
lacks out.txt "not in the tree"; lacks out.txt "at zero size"
verdict

# The read that names the state can find the element after all. A dump slower
# than the timeout makes the poll a single one, so the second dump is that last
# read, whatever the clock does.
dev_case zero-wait-last-read-finds
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
screen "$case_dir/adb/dump-2.xml" "$ROOT_NODE" "$SIZED_BTN"
printf '1.2' > "$case_dir/adb/dump-delay"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_flow "$case_dir/flow.json"
begin "waitForId: an element the last read finds after the timeout passes the step"
status_is 0; fake_used; reads_are 2; has out.txt "'btn' on screen at 175 65 after"
lacks out.txt "not on screen"
verdict

dev_case optional-goes-on
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_flow "$case_dir/flow.json"
begin "optional: a wait that ends without its element is skipped, and the flow goes on"
status_is 0; fake_used
has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60] - optional, the flow goes on"
has out.txt 'step 2 '"'"'wait'"'"' "the step after"'
has res/flow.xml 'skipped="1"'
has res/flow.xml "optional wait ended, the flow went on: 'btn' not on screen after 1s - at zero size [174,60][174,60]"
lacks res/flow.xml "condition not met"; lacks res/flow.xml "<failure"
verdict

dev_case optional-found
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SIZED_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }'
run_flow "$case_dir/flow.json"
begin "optional: an element that is there is waited for as always"
status_is 0; fake_used; has out.txt "'btn' on screen at 175 65"
has res/flow.xml 'skipped="0"'
verdict

dev_case optional-false
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": false }'
run_flow "$case_dir/flow.json"
begin "optional: false is the ordinary wait, and fails"
status_is 1; fake_used; red_is failure StepFailed 1 0
verdict

dev_case optional-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_flow "$case_dir/flow.json"
begin "optional: a screen that cannot be read still stops the flow"
status_is 1; fake_used; red_is error DeviceError 0 1; lacks out.txt "the step after"
verdict

dev_case zero-when-holds
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an element in the tree at zero size holds"
status_is 0; fake_used; has out.txt '"guarded step"'; lacks out.txt "skipped"
verdict

dev_case zero-when-missing
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an id that is not in the tree does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
has res/flow.xml "condition not met: zeroSizeId 'btn'"
verdict

dev_case zero-when-sized
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$SIZED_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: an element of a real size does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
verdict

dev_case zero-when-namesake
screen "$case_dir/adb/dump-1.xml" "$ROOT_NODE" "$ZERO_BTN" "$SIZED_BTN"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: a zero-size node with a namesake that can be tapped does not hold"
status_is 0; fake_used; has out.txt "skipped: zeroSizeId 'btn'"
verdict

dev_case zero-when-unreadable
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" "$RAN"
run_flow "$case_dir/flow.json"
begin "zeroSizeId: a screen that cannot be read stops the flow"
status_is 1; fake_used; has out.txt "when (zeroSizeId 'btn')"; has res/flow.xml 'name="00 flow"'
verdict

# iOS: the same states in an idb tree. The window comes first, as the engine
# takes it for the screen.
IAPP='{"type":"Application","role_description":"application","AXLabel":"App","frame":{"x":0,"y":0,"width":402,"height":874}}'
IZERO='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":174,"y":60,"width":0,"height":0}}'
ISIZED='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":100,"y":40,"width":150,"height":50}}'

ios_case ios-zero-wait
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on a zero-size element says so, with its corners"
status_is 1; has out.txt "'btn' not on screen after 1s - at zero size [174,60][174,60]"
verdict

ios_case ios-zero-wait-missing
tree "$case_dir/idb/desc-1.json" "$IAPP"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on an id that is not in the tree says so"
status_is 1; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

IOFF='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask","frame":{"x":100,"y":2000,"width":150,"height":50}}'
ios_case ios-zero-wait-outside
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IOFF"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: a timeout on an element below the screen says so"
status_is 1; has out.txt "'btn' not on screen after 1s - outside the screen at [100,2000][250,2050]"
verdict

# An element with no frame has no place: not in the tree, as a node without
# bounds is on Android - not zero size.
INOFRAME='{"type":"Button","role_description":"button","AXUniqueId":"btn","AXLabel":"Ask"}'
ios_case ios-zero-wait-noframe
tree "$case_dir/idb/desc-1.json" "$IAPP" "$INOFRAME"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1 }'
run_ios "$case_dir/flow.json"
begin "waitForId on iOS: an element with no frame is not in the tree"
status_is 1; has out.txt "'btn' not on screen after 1s - not in the tree"
verdict

ios_case ios-zero-when-noframe
tree "$case_dir/idb/desc-1.json" "$IAPP" "$INOFRAME"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element with no frame does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-optional-goes-on
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 1, "optional": true }' \
  '{ "do": "wait", "value": "0", "title": "the step after" }'
run_ios "$case_dir/flow.json"
begin "optional on iOS: a wait that ends without its element is skipped, and the flow goes on"
status_is 0; has out.txt "at zero size [174,60][174,60] - optional, the flow goes on"
has out.txt '"the step after"'; has res/flow.xml "optional wait ended, the flow went on"
verdict

ios_case ios-zero-when-holds
tree "$case_dir/idb/desc-1.json" "$IAPP" "$IZERO"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element in the tree at zero size holds"
status_is 0; has out.txt '"guarded step"'; lacks out.txt "skipped"
verdict

ios_case ios-zero-when-missing
tree "$case_dir/idb/desc-1.json" "$IAPP"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an id that is not in the tree does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-zero-when-sized
tree "$case_dir/idb/desc-1.json" "$IAPP" "$ISIZED"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: an element of a real size does not hold"
status_is 0; has out.txt "skipped: zeroSizeId 'btn'"
verdict

ios_case ios-zero-when-unreadable
printf 'not a tree' > "$case_dir/idb/desc-1.json"
flow_file "$case_dir/flow.json" "$RAN"
run_ios "$case_dir/flow.json"
begin "zeroSizeId on iOS: a screen that cannot be read stops the flow"
status_is 1; has out.txt "when (zeroSizeId 'btn')"
verdict

# The builder: what a file says is checked before anything runs.
new_case optional-check
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "timeout": 20, "optional": true }' \
  '{ "do": "tapId", "value": "bell", "when": { "zeroSizeId": "btn" } }'
expect "check: optional and zeroSizeId build" 0 " - 2 steps" check "$case_dir/flow.json"

new_case optional-not-bool
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "btn", "optional": "yes" }'
expect "check: optional that is not a boolean is refused" 1 \
  "step 1 'waitForId': \"optional\" is true or false, got \"yes\"" check "$case_dir/flow.json"

new_case optional-wrong-step
flow_file "$case_dir/flow.json" '{ "do": "waitFor", "value": "Ask", "optional": true }'
expect "check: optional on a step that does not take it is refused" 1 \
  "step 1 'waitFor': step 'waitFor' does not take \"optional\" - only waitForId does" check "$case_dir/flow.json"

new_case optional-on-include
flow_file "$case_dir/flow.json" '{ "do": "include", "value": "b1.json", "optional": true }'
flow_file "$case_dir/b1.json" '{ "do": "wait", "value": "0" }'
expect "check: optional on an include is refused" 1 \
  "'optional' is not a key an include takes" check "$case_dir/flow.json"

new_case zero-when-not-text
flow_file "$case_dir/flow.json" '{ "do": "wait", "value": "0", "when": { "zeroSizeId": { "id": "btn" } } }'
expect "check: a zeroSizeId that is not text is refused" 1 \
  "condition 'zeroSizeId' must be text or a number" check "$case_dir/flow.json"

# ── a crashed app, not a missing element (#63) ───────────────────────────────
# After a failed step the engine asks the device whether the app of this run
# ($YUKTI_VARIANT) is still running and in front, and keeps its crash log. The
# fake adb answers from app-pid, focus, device-offset and crash.
app_cfg(){ printf '{ "variants": { "app": { "platform": "%s", "%s": "com.example" } } }\n' \
  "${1:-android}" "${2:-package}" > "$case_dir/cfg.json"; }
app_case(){ dev_case "$1"; app_cfg; screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)" "$(node TextView marker "$MARK")"
  flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'; }
run_app(){ run_flow "$case_dir/flow.json" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json" "$@"; }
FRONT='  mCurrentFocus=Window{7f3a2c1 u0 com.example/com.example.MainActivity}'
CRASH='--------- beginning of crash
10-19 23:40:01.123  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main
10-19 23:40:01.123  4242  4242 E AndroidRuntime: java.lang.IllegalStateException: bad address user.synthetic@example.invalid'
asked(){ grep -qF -- "$1" "$case_dir/adb/log" || no "the device was never asked: $1"; }
not_asked(){ ! grep -qF -- "$1" "$case_dir/adb/log" 2>/dev/null || no "the device was asked: $1"; }

app_case app-front
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' "$FRONT" > "$case_dir/adb/focus"
run_app
begin "app: running and in front - the step's message as before, and a note"
status_is 1; fake_used; red_is failure StepFailed 1 0
has res/flow.xml "not on screen"; has res/flow.xml "app: com.example running, in front"
lacks res/flow.xml "is not running"; has res/flow.xml "crash log: none since the flow started"
verdict

app_case app-gone
printf '%s\n' "$CRASH" > "$case_dir/adb/crash"; echo 3600 > "$case_dir/adb/device-offset"
flow_file "$case_dir/flow.json" '{ "do": "type", "value": "${TEST_EMAIL}" }' \
  '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
screen "$case_dir/adb/dump-1.xml" "$(node EditText email @TYPED@ true)" "$(node TextView marker "$MARK")"
t_before=$(date +%s); run_app TEST_EMAIL='user.synthetic@example.invalid'; t_after=$(date +%s)
begin "app: gone - said first, its own type, and the crash log kept masked"
status_is 1; fake_used; red_is failure AppGone 1 0
has res/flow.xml 'message="the app com.example is not running: it was gone when the step failed'
has res/flow.xml "not on screen"; has res/flow.xml "crash log: flow-crash.txt (3 lines)"
has res/flow.xml "flow-crash.txt</system-out>"; file_full res/flow-crash.txt
has res/flow-crash.txt "FATAL EXCEPTION"; has res/flow-crash.txt "[typed]"; lacks res/flow-crash.txt "user.synthetic"
since="$(grep -oE 'logcat -b crash -d -v threadtime -t [^ ]+' "$case_dir/adb/log" | awk '{print $NF}')"
printf '%s' "$since" | grep -qE '^[0-9]+\.[0-9]{3}$' || no "logcat -t got '$since', not a time with a fraction"
awk -v s="$since" -v a="$t_before" -v b="$t_after" 'BEGIN { exit !(s >= a + 3597 && s <= b + 3599) }' \
  || no "logcat -t $since is not the flow's start on the device clock ($t_before..$t_after + 3600)"
verdict

app_case app-behind
echo 4242 > "$case_dir/adb/app-pid"
printf '%s\n' '  mCurrentFocus=Window{1b2c3d4 u0 com.android.launcher3/com.android.launcher3.uioverride.QuickstepLauncher}' > "$case_dir/adb/focus"
run_app
begin "app: running but not in front - the window that is, without its hash"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml 'message="the app com.example is running but not in front: com.android.launcher3/com.android.launcher3.uioverride.QuickstepLauncher'
lacks res/flow.xml "1b2c3d4"; asked "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"
verdict

app_case app-focus-null
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=null' > "$case_dir/adb/focus"
run_app
begin "app: no focused window is not read as another app in front"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: no focused window"; lacks res/flow.xml "not in front"
verdict

app_case app-focus-popup
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=Window{9e8f7a6 u0 PopupWindow:3c1d2e5}' > "$case_dir/adb/focus"
run_app
begin "app: a focused popup has no package and says so"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: focused window has no package (PopupWindow:3c1d2e5)"; lacks res/flow.xml "not in front"
verdict

app_case app-crash-dialog
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' '  mCurrentFocus=Window{c7b4574 u0 Application Error: com.example}' \
  '  mFocusedApp=ActivityRecord{e263aa3 u0 com.example/.Main t45}' > "$case_dir/adb/focus"
run_app
begin "app: the system's crash dialog is named, and not taken for the app in front"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app state not read: the system shows the crash dialog of com.example"; lacks res/flow.xml "running, in front"
verdict

app_case app-no-variant
run_flow "$case_dir/flow.json" YUKTI_CONFIG="$case_dir/cfg.json"
begin "app: no variant for the run - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml 'app: not checked - no variant for this run ($YUKTI_VARIANT is not set)'; not_asked "pidof com.example"
verdict

app_case app-no-config
run_flow "$case_dir/flow.json" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/none.json"
begin "app: a variant with no config - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml "app: not checked - no config at"; not_asked "pidof com.example"
verdict

app_case app-no-package
app_cfg android bundleId
run_app
begin "app: a variant with no package - not checked, the result still written"
status_is 1; file_full res/flow.xml; red_is failure StepFailed 1 0
has res/flow.xml "app: not checked - variant 'app' has no 'package' in"; not_asked "pidof com.example"
verdict

dev_case app-pass
app_cfg; screen "$case_dir/adb/dump-1.xml" "$(node TextView title Today)"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
run_app
env ANDROID_HOME="$ROOT/tests/fake-sdk" FAKE_ADB_DIR="$case_dir/adb" YUKTI_PLATFORM=android YUKTI_HELPER=0 \
  YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json" YUKTI_RESULTS_DIR="$case_dir/res" TMPDIR="$case_dir/tmp" \
  "$YUKTI" flow --check "$case_dir/flow.json" > /dev/null 2>&1
begin "app: a flow that passes, and --check, ask nothing about the app"
status_is 0; fake_used; not_asked "pidof com.example"; not_asked "logcat"; file_absent res/flow-crash.txt
verdict

app_case app-pidof-hangs
echo hang > "$case_dir/adb/app-pid"
t0=$SECONDS; run_app; took=$((SECONDS - t0))
begin "app: a device that does not answer is asked once, within the budget"
status_is 1; red_is failure StepFailed 1 0
[ "$took" -lt 40 ] || no "the run took ${took}s"
has res/flow.xml "app state not read: no answer in 10 s"; has res/flow.xml "crash log not read:"
not_asked "dumpsys window"; not_asked "logcat"
verdict

app_case app-screencap-hangs
echo hang > "$case_dir/adb/screencap"
run_app
begin "app: after a screenshot that never answered, the app is not asked about"
status_is 1; has res/flow.xml "app state not read: the device did not answer the screenshot"
not_asked "pidof com.example"; not_asked "logcat"
verdict

app_case app-crash-hangs
echo 4242 > "$case_dir/adb/app-pid"; printf '%s\n' "$FRONT" > "$case_dir/adb/focus"; echo hang > "$case_dir/adb/crash"
run_app
begin "app: a crash log that does not come is not reported as no crash"
status_is 1; has res/flow.xml "crash log not read: no answer in 10 s"; lacks res/flow.xml "none since the flow started"
file_absent res/flow-crash.txt
verdict

app_case app-device-error
echo 4242 > "$case_dir/adb/app-pid"
printf 'not a dump' > "$case_dir/adb/dump-1.xml"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "title", "timeout": 1 }'
rm -f "$case_dir/adb/app-pid"
run_app
begin "app: a device error stays an error, the app line is added"
status_is 1; red_is error DeviceError 0 1
has res/flow.xml "is not running: it was gone when the step failed"
verdict

app_case app-stopped-by-flow
flow_file "$case_dir/flow.json" '{ "do": "clearState", "value": "app" }' '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_app
begin "app: stopped by the flow itself is not a crash"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app: com.example not running - stopped by step 1"; lacks res/flow.xml "it was gone"
verdict

ios_case app-ios-gone
mkdir -p "$case_dir/xcrun" "$case_dir/reports"; app_cfg ios bundleId
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')"
printf 'PID\tStatus\tLabel\n-\t0\tcom.apple.springboard\n' > "$case_dir/xcrun/launchctl"
printf '{"bundleID":"com.example","exception":"EXC_CRASH"}\n' > "$case_dir/reports/Example-2026-10-19-234001.ips"
printf '{"bundleID":"com.example","exception":"OLD"}\n' > "$case_dir/reports/Example-old.ips"
touch -t 202001010000 "$case_dir/reports/Example-old.ips"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_ios "$case_dir/flow.json" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_IOS_CRASH_DIR="$case_dir/reports" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"
begin "app on iOS: gone in launchctl, the newest report of the run kept"
status_is 1; red_is failure AppGone 1 0
has res/flow.xml "the app com.example is not running: it was gone when the step failed"
file_full res/flow-crash.ips; has res/flow-crash.ips "EXC_CRASH"; lacks res/flow-crash.ips "OLD"
verdict

ios_case app-ios-running
mkdir -p "$case_dir/xcrun" "$case_dir/reports"; app_cfg ios bundleId
tree "$case_dir/idb/desc-1.json" "$(itext name 100 '"Ada"')"
printf 'PID\tStatus\tLabel\n4242\t0\tUIKitApplication:com.example[1a2b][rb-legacy]\n' > "$case_dir/xcrun/launchctl"
flow_file "$case_dir/flow.json" '{ "do": "waitForId", "value": "missing", "timeout": 1 }'
run_ios "$case_dir/flow.json" PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun" YUKTI_IOS_CRASH_DIR="$case_dir/reports" YUKTI_VARIANT=app YUKTI_CONFIG="$case_dir/cfg.json"
begin "app on iOS: running - a note, and no report yet"
status_is 1; red_is failure StepFailed 1 0
has res/flow.xml "app: com.example running"; has res/flow.xml "crash log: no crash report yet in DiagnosticReports"
verdict

# ── Studio: the screen tree behind Inspect (#125) ───────────────────────────
# Studio read `yukti ui` only as idb's JSON and swallowed the error on a
# uiautomator dump, so on Android its element list was always empty. The
# reader is checked as functions (imported, no server) and through a live
# Studio on a free port, driving the same fakes the engine cases use.

# studio_py <python> - run python with Studio's module importable as `server`.
studio_py(){ "$PY3" -c "import sys; sys.path.insert(0, '$ROOT/studio'); import server
$1" > "$case_dir/out.txt" 2>&1; run_status=$?; }

# studio_get <route> [VAR=value...] - start Studio against this case's fakes,
# GET the route once, keep the answer in $case_dir/answer.json, stop Studio.
studio_get(){ local route="$1"; shift
  env -u ANDROID_SDK_ROOT -u YUKTI_VARIANT -u YUKTI_DEVICE_PT_W -u YUKTI_DEVICE_PT_H \
    ANDROID_HOME="$ROOT/tests/fake-sdk" YUKTI_HELPER=0 YUKTI_CONFIG="$case_dir/cfg.json" \
    FAKE_ADB_DIR="$case_dir/adb" FAKE_IDB_DIR="$case_dir/idb" TMPDIR="$case_dir/tmp" "$@" \
    "$PY3" - "$ROOT/studio/server.py" "$route" > "$case_dir/answer.json" 2> "$case_dir/out.txt" <<'PY'
import os, socket, subprocess, sys, time, urllib.error, urllib.request
srv, route = sys.argv[1:3]
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
p = subprocess.Popen([sys.executable, srv], env=dict(os.environ, YUKTI_STUDIO_PORT=str(port)),
                     stdout=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            body = urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, route), timeout=60).read()
            break
        except urllib.error.URLError:
            time.sleep(0.1)
    else:
        sys.exit("Studio did not answer on port %d" % port)
    sys.stdout.write(body.decode("utf-8"))
finally:
    p.terminate(); p.wait()
PY
  run_status=$?; }

# answer <python expression over a, the answer> - one claim about the answer.
answer(){ "$PY3" -c "import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" \
  "$case_dir/answer.json" 2>/dev/null || no "answer is not: $1"; }

# A nested dump: a frame holding a tab with an id, a bare view, and a card with
# a button inside it. The bare view has neither id nor text and is still a node
# of the tree, as uiautomatorviewer shows it.
nested_dump(){ printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hierarchy rotation="0">' \
  '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" enabled="true" scrollable="false" bounds="[0,0][1080,2400]">' \
  '<node index="0" text="Today" resource-id="com.example:id/today-tab" class="android.widget.TextView" content-desc="" clickable="true" enabled="true" scrollable="false" bounds="[0,2200][540,2400]" />' \
  '<node index="1" text="" resource-id="" class="android.view.View" content-desc="" clickable="false" enabled="true" scrollable="false" bounds="[540,2200][1080,2400]" />' \
  '<node index="2" text="" resource-id="com.example:id/card" class="android.view.ViewGroup" content-desc="Water card" clickable="true" enabled="true" scrollable="false" bounds="[40,400][1040,800]">' \
  '<node index="0" text="Add" resource-id="com.example:id/card-add" class="android.widget.Button" content-desc="" clickable="true" enabled="false" scrollable="false" bounds="[800,600][1000,760]" />' \
  '</node></node></hierarchy>'; }

new_case studio-tree-dump
nested_dump > "$case_dir/dump.xml"
studio_py "
u, n = server.parse_tree(open('$case_dir/dump.xml').read())
assert u == 'px', u
assert len(n) == 5, len(n)
assert [x['id'] for x in n] == ['', 'today-tab', '', 'card', 'card-add'], [x['id'] for x in n]
assert n[1]['rid'] == 'com.example:id/today-tab' and n[1]['text'] == 'Today'
assert [x['parent'] for x in n] == [None, 0, 0, 0, 3] and [x['depth'] for x in n] == [0, 1, 1, 1, 2]
assert n[4]['bounds'] == [800, 600, 1000, 760] and n[4]['enabled'] is False and n[4]['clickable'] is True
assert n[3]['desc'] == 'Water card'
e = server.legacy_elements(n)
assert [(x['label'], x['x'], x['y']) for x in e] == [('Today', 270, 2300), ('Water card', 540, 600), ('Add', 900, 680)], e
print('tree ok')"
begin "studio: a uiautomator dump is a tree with ids, nesting and boxes in px"
status_is 0; has out.txt "tree ok"
verdict

new_case studio-tree-idb
tree "$case_dir/desc.json" "$(itext email 100 '"ada@example.com"')" \
  '{"type":"Button","AXUniqueId":"","AXLabel":"Sign in","AXValue":null,"enabled":true,"frame":{"x":40.5,"y":200,"width":300,"height":44}}'
studio_py "
u, n = server.parse_tree(open('$case_dir/desc.json').read())
assert u == 'pt', u
assert [(x['id'], x['text'], x['desc'], x['cls']) for x in n] == [('email', '', 'ada@example.com', 'TextField'), ('', 'Sign in', '', 'Button')], n
assert n[1]['bounds'] == [40.5, 200, 340.5, 244] and n[1]['enabled'] is True
assert [x['depth'] for x in n] == [0, 0] and [x['parent'] for x in n] == [None, None]
# The old list, exactly as before: AXLabel, else AXValue, and the centre.
assert [(x['label'], x['type'], x['x'], x['y']) for x in server.legacy_elements(n)] == [('ada@example.com', 'TextField', 190, 120), ('Sign in', 'Button', 190, 222)]
print('idb ok')"
begin "studio: an idb tree is a flat list with AXUniqueId as the id, boxes in pt"
status_is 0; has out.txt "idb ok"
verdict

new_case studio-tree-garbage
studio_py "
for raw, word in (('<hierarchy><node', 'does not parse'), ('[{', 'does not parse'), ('{}', 'neither'), ('error: no device', 'neither')):
    try:
        server.parse_tree(raw)
    except ValueError as e:
        assert word in str(e), (raw, str(e))
    else:
        raise AssertionError('parsed: %r' % raw)
a = server.ui_answer(0, '<hierarchy><node', '')
assert a['outcome'] == 'not_read' and 'does not parse' in a['error'] and a['elements'] == [], a
assert server.ui_answer(0, '', '')['outcome'] == 'empty'
assert server.ui_answer(0, '<hierarchy rotation=\"0\"></hierarchy>', '')['outcome'] == 'empty'
print('garbage ok')"
begin "studio: an answer it cannot read is not_read with the reason, never an empty screen"
status_is 0; has out.txt "garbage ok"
verdict

new_case studio-pick
nested_dump > "$case_dir/dump.xml"
studio_py "
u, n = server.parse_tree(open('$case_dir/dump.xml').read())
pick = lambda x, y: (server.pick_at(n, x, y) or {}).get('i')
assert pick(900, 700) == 4      # the button, not the card or the frame around it
assert pick(100, 500) == 3      # the card
assert pick(700, 2300) == 2     # the bare view: no id, no text, still the node there
assert pick(540, 2300) == 2     # left edge belongs to the box ...
assert pick(539, 2300) == 1     # ... the right edge does not
assert pick(1080, 100) is None  # past the right edge of the screen
z = [dict(n[0], i=0, bounds=[0, 0, 0, 0]), dict(n[0], i=1, depth=1, bounds=[10, 10, 20, 20]), dict(n[0], i=2, depth=2, bounds=[10, 10, 20, 20]), dict(n[0], i=3, depth=2, bounds=[10, 10, 20, 20])]
assert server.pick_at(z, 0, 0) is None             # an empty box is never picked
assert server.pick_at(z, 15, 15)['i'] == 3         # a tie: deeper, then later
print('pick ok')"
begin "studio: the node under a point is the smallest box holding it"
status_is 0; has out.txt "pick ok"
verdict

dev_case studio-ui-android
nested_dump > "$case_dir/adb/dump-1.xml"
studio_get /api/ui YUKTI_PLATFORM=android
begin "studio: /api/ui on Android reads the dump - nodes, units, and the old list"
status_is 0; fake_used
answer 'a["outcome"] == "ok" and a["ok"] is True and a["units"] == "px"'
answer '[n["id"] for n in a["nodes"]] == ["", "today-tab", "", "card", "card-add"]'
answer '[e["label"] for e in a["elements"]] == ["Today", "Water card", "Add"]'
answer 'a["raw"].startswith("<?xml")'
verdict

ios_case studio-ui-ios
tree "$case_dir/idb/desc-1.json" "$(itext email 100 '"ada@example.com"')"
studio_get /api/ui YUKTI_PLATFORM=ios PATH="$ROOT/tests/fake-sdk/idb-bin:$PATH"
begin "studio: /api/ui on iOS - the old list as before, and the id from AXUniqueId"
status_is 0
answer 'a["outcome"] == "ok" and a["units"] == "pt"'
answer 'a["elements"] == [{"label": "ada@example.com", "type": "TextField", "x": 190, "y": 120}]'
answer '[n["id"] for n in a["nodes"]] == ["email"]'
[ -s "$case_dir/idb/log" ] || no "the fake idb was never called"
verdict

ios_case studio-inspect-ios
mkdir -p "$case_dir/xcrun"
tree "$case_dir/idb/desc-1.json" "$(itext email 100 '"ada@example.com"')"
studio_get /api/inspect YUKTI_PLATFORM=ios PATH="$ROOT/tests/fake-sdk/xcrun-bin:$ROOT/tests/fake-sdk/idb-bin:$PATH" \
  FAKE_XCRUN_DIR="$case_dir/xcrun"
begin "studio: /api/inspect on iOS - simulator screenshot, idb tree, boxes in the device's points"
status_is 0
answer '__import__("base64").b64decode(a["png"]).startswith(b"\x89PNG")'
answer 'a["outcome"] == "ok" and a["units"] == "pt" and (a["pt_w"], a["pt_h"]) == (402, 874)'
answer '[n["id"] for n in a["nodes"]] == ["email"]'
has xcrun/log "screenshot"
[ -s "$case_dir/idb/log" ] || no "the fake idb was never called"
verdict

dev_case studio-ui-not-read
: > "$case_dir/adb/running"     # a helper holds the device: every dump comes back empty
studio_get /api/ui YUKTI_PLATFORM=android
begin "studio: /api/ui when the screen cannot be read - not_read with the engine's reason"
status_is 0; fake_used
answer 'a["outcome"] == "not_read" and a["ok"] is False and a["elements"] == [] and a["nodes"] == []'
answer '"uiautomator produced no usable dump" in a["error"] and "\x1b" not in a["error"]'
verdict

dev_case studio-inspect-android
nested_dump > "$case_dir/adb/dump-1.xml"
studio_get /api/inspect YUKTI_PLATFORM=android
begin "studio: /api/inspect - the screenshot and the tree in one answer"
status_is 0; fake_used
answer '__import__("base64").b64decode(a["png"]).startswith(b"\x89PNG")'
answer 'a["outcome"] == "ok" and a["units"] == "px" and len(a["nodes"]) == 5 and "raw" not in a'
answer 'all(k in a for k in ("png_w", "png_h", "pt_w", "pt_h"))'
has adb/log "exec-out screencap"
verdict

dev_case studio-inspect-no-shot
nested_dump > "$case_dir/adb/dump-1.xml"
echo fail > "$case_dir/adb/screencap"
studio_get /api/inspect YUKTI_PLATFORM=android
begin "studio: /api/inspect without a screenshot - not_read, and no tree read for it"
status_is 0; fake_used
answer 'a["outcome"] == "not_read" and a["error"] and "png" not in a'
lacks adb/log "uiautomator dump"
verdict

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
