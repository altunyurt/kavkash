#!/bin/sh
# query.sh COUNT [QUERY [CWD [SESSION [OFFSET]]]] — history back-end.
# Asks the daemon for the newest COUNT DISTINCT commands starting at
# OFFSET (COUNT=0 = all — no LIMIT), one row per unique command, newest
# first. QUERY = anchored prefix filter, CWD/SESSION = server-side scope
# (cwd matches the dir + subtree; empty = global). Output: NUL-separated
# rows: "dur ✓/✗ age\x1fcommand\x1fid" — uniform \x1f field separator,
# metadata first (fzf shows fields 1+2, matches field 2, the id feeds
# shift-delete).

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
fi
