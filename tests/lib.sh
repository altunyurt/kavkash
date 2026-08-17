#!/bin/sh
# tests/lib.sh — asserts, sandbox fixtures, netstring helpers.
# Sourced by every t-*.sh; each test file runs in its own process.

KAVKASH_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

TESTS_PASS=0
TESTS_FAIL=0
CURRENT=""

t_begin() { CURRENT="$1"; }
t_ok() { TESTS_PASS=$((TESTS_PASS + 1)); }
t_fail() {
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "FAIL [$CURRENT] $*" >&2
}
t_eq() { # t_eq EXPECTED ACTUAL MSG
    if [ "$1" = "$2" ]; then
        t_ok
    else
        t_fail "$3 (expected [$1], got [$2])"
    fi
}
t_contains() { # t_contains NEEDLE HAYSTACK MSG
    case "$2" in
        *"$1"*) t_ok ;;
        *) t_fail "$3 (missing [$1] in [$2])" ;;
    esac
}
t_rc() { # t_rc EXPECTED_RC MSG CMD...
    want=$1
    msg=$2
    shift 2
    "$@" > /dev/null 2>&1
    rc=$?
    if [ "$rc" = "$want" ]; then
        t_ok
    else
        t_fail "$msg (expected rc $want, got $rc)"
    fi
}
t_summary() {
    echo "$(basename "$0"): $TESTS_PASS passed, $TESTS_FAIL failed"
    [ "$TESTS_FAIL" -eq 0 ]
}

# Fresh sandbox: throwaway XDG dirs + the shared includes (paths and
# kav_db). Every daemon/hook/CLI child inherits the env, so nothing can
# touch the developer's real installation.
sandbox_new() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/kavkash-test.XXXXXX")
    export XDG_DATA_HOME="$SANDBOX/data" XDG_RUNTIME_DIR="$SANDBOX/run"
    mkdir -p "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
    . "$KAVKASH_DIR/includes.sh"
}

daemon_start() {
    "$KAVKASH_DIR/server.sh" > "$SANDBOX/server.out" 2>&1 &
    DAEMON_PID=$!
    i=0
    while [ $i -lt 100 ] && [ ! -S "$KAV_SOCK_FILE" ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -S "$KAV_SOCK_FILE" ] || t_fail "daemon socket did not appear"
}
daemon_stop() {
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2> /dev/null
    wait "$DAEMON_PID" 2> /dev/null
    DAEMON_PID=""
}

# Netstring wire helpers (same framing hook.sh uses).
ns_field() {
    printf '%s:%s,' "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" "$1"
}
ns_send() { # ns_send TYPE FIELD...
    type=$1
    shift
    msg="1:$type,"
    for f in "$@"; do
        msg="$msg$(ns_field "$f")"
    done
    printf '%s' "$msg" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1
}

# Q helpers: rows as lines, payload stripped to the bare command
# (\x1f<id> suffix, "dur ✓/✗ age\x1d" prefix).
q_rows() { # q_rows COUNT [QUERY [CWD [SESSION [OFFSET]]]]
    "$KAVKASH_DIR/query.sh" "$@" | tr '\0' '\n' | sed 's/\x1f.*//; s/^[^\x1d]*\x1d//'
}
q_raw() { # q_raw COUNT [QUERY [...]] — unstripped rows for payload asserts
    "$KAVKASH_DIR/query.sh" "$@" | tr '\0' '\n'
}
