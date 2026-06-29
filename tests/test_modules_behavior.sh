#!/bin/sh
# Behavioral tests for the community modules under modules/.
#
# These drive each real module over JSONL (handshake + a command event + a
# normal message) and assert the SHAPE of the responses, not random values.

set -eu

PASS=0
FAIL=0
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

HS='{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}'

pass() {
    echo "PASS $1"
    PASS=$((PASS + 1))
}

fail_case() {
    echo "FAIL $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    FAIL=$((FAIL + 1))
}

# module_out MODULE_DIR ENTRYPOINT LINE...  -> prints module stdout
module_out() {
    dir=$1
    entry=$2
    shift 2
    ( cd "$ROOT/$dir" && printf '%s\n' "$@" | "./$entry" )
}

# msg.created event with a given sender + plain_text
event() {
    sender=$1
    text=$2
    printf '{"type":"message.created","message":{"sender":"%s","plain_text":"%s"}}' \
        "$sender" "$text"
}

assert_match() {
    label=$1
    haystack=$2
    pattern=$3
    if printf '%s' "$haystack" | grep -Eq "$pattern"; then
        pass "$label"
    else
        fail_case "$label" "$haystack"
    fi
}

assert_no_match() {
    label=$1
    haystack=$2
    pattern=$3
    if printf '%s' "$haystack" | grep -Eq "$pattern"; then
        fail_case "$label" "$haystack"
    else
        pass "$label"
    fi
}

echo "=== TNT Modules Behavior Tests ==="

# --- flip-module ---
out=$(module_out modules/flip-module flip-module.sh \
    "$HS" "$(event alice /flip)" "$(event other 'hello there')")
assert_match "flip: handshake.ok" "$out" '"type":"handshake.ok"'
assert_match "flip: heads or tails" "$out" '"type":"message.create".*(heads|tails)'
assert_match "flip: normal message is a no-op" "$out" '"type":"event.ok"'
assert_no_match "flip: /flipper does not trigger here" \
    "$(module_out modules/flip-module flip-module.sh "$(event x /flipper)")" \
    '"type":"message.create"'

# --- 8ball-module ---
out=$(module_out modules/8ball-module 8ball-module.sh \
    "$HS" "$(event bob '/8ball will it work?')" "$(event other plain)")
assert_match "8ball: handshake.ok" "$out" '"type":"handshake.ok"'
assert_match "8ball: answers the question" "$out" '"type":"message.create"'
assert_match "8ball: normal message is a no-op" "$out" '"type":"event.ok"'

# --- choose-module ---
out=$(module_out modules/choose-module choose-module.sh \
    "$HS" "$(event cara '/choose tea | coffee | water')")
assert_match "choose: picks an option" "$out" '"type":"message.create".*chose: (tea|coffee|water)'
out=$(module_out modules/choose-module choose-module.sh \
    "$(event cara '/choose onlyone')")
assert_match "choose: too few options shows usage" "$out" 'usage'

# --- quote-module ---
out=$(module_out modules/quote-module quote-module.sh \
    "$HS" "$(event dan /quote)" "$(event other plain)")
assert_match "quote: handshake.ok" "$out" '"type":"handshake.ok"'
assert_match "quote: shares a quote" "$out" '"type":"message.create"'
assert_match "quote: normal message is a no-op" "$out" '"type":"event.ok"'

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
