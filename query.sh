#!/bin/sh
# query.sh COUNT [QUERY [CWD [SESSION]]] — history picker back-end.
#
# Asks the daemon for the newest COUNT commands. QUERY is accepted for wire
# compatibility and ignored — the picker passes an empty query and fzf
# filters the loaded window in-memory (the server-side subsequence matcher
# was removed). CWD/SESSION scope the server-side query (empty = global):
# cwd matches the directory and its subtree, session matches a per-shell
# token. Scoped queries first probe the server's version (Q v): a pre-
# v0.4.0 daemon ignores the scope fields and would silently return global
# rows, so the probe bails out to an empty picker instead.
#
# Output: NUL-separated raw command rows for fzf --read0. Multi-line commands
# pass through verbatim (fzf >= 0.53 renders them natively); nothing is
# escaped. Passed through as-is.

. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

count="${1:-10000}"
query="${2:-}"
cwd="${3:-}"
session="${4:-}"
case "$count" in '' | *[!0-9]*) count=10000 ;; esac

# netstring field: "len:payload,"
_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

if [ -n "$cwd" ] || [ -n "$session" ]; then
    v=""
    if command -v socat > /dev/null 2>&1; then
        v=$(printf '1:Q,1:v,' | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null)
    elif command -v nc > /dev/null 2>&1; then
        v=$(printf '1:Q,1:v,' | nc -U "$KAV_SOCK_FILE" 2> /dev/null)
    else
        exit 0
    fi
    # require the scope protocol (>= 0.4.0); empty reply = old daemon
    printf '%s\n' "$v" | awk -F. 'NR == 1 { exit ($1 > 0 || ($1 == 0 && $2 >= 4)) ? 0 : 1 }' || exit 0
fi

payload=$(printf '1:Q,%s%s%s%s%s%s%s%s' "$(_ns search)" "$(_ns "$query")" "$(_ns "$count")" "$(_ns "$cwd")" "$(_ns "$session")")

# Stream straight to stdout: command substitution would drop NUL bytes.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$payload" | nc -U "$KAV_SOCK_FILE" 2> /dev/null
else
    exit 0
fi
