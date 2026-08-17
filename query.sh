#!/bin/sh
# query.sh COUNT [QUERY [CWD [SESSION [OFFSET]]]] — history back-end.
#
# Asks the daemon for the newest COUNT DISTINCT commands starting at
# OFFSET (COUNT=0 = all of them — the server sends no LIMIT). The server
# returns one row per unique command, newest occurrence first.
# The Ctrl+R picker loads the whole set (COUNT=0) and lets fzf filter
# in-memory; the Up/Down stepper walks it in batches of 50, passing the
# typed line as QUERY to restrict the walk to commands starting with it
# (empty QUERY = no filter). CWD/SESSION scope the server-side query
# (empty = global): cwd matches the dir + subtree, session a per-shell
# token.
#
# Output: NUL-separated rows — "dur ✓/✗ age\x1d" metadata + the raw
# command (multi-line commands pass through verbatim; fzf renders them
# natively).

. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

count="${1:-10000}"
query="${2:-}"
cwd="${3:-}"
session="${4:-}"
offset="${5:-0}"
case "$count" in '' | *[!0-9]*) count=10000 ;; esac
case "$offset" in '' | *[!0-9]*) offset=0 ;; esac

# netstring field: "len:payload," (len in BYTES — LC_ALL=C wc -c, not ${#x})
_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

payload=$(printf '1:Q,%s%s%s%s%s%s%s%s%s' "$(_ns search)" "$(_ns "$query")" "$(_ns "$count")" "$(_ns "$cwd")" "$(_ns "$session")" "$(_ns "$offset")")

# Stream straight to stdout: command substitution would drop NUL bytes.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$payload" | nc -U "$KAV_SOCK_FILE" 2> /dev/null
else
    exit 0
fi
