#!/bin/sh
# query.sh COUNT [QUERY] — history picker back-end.
#
# Asks the daemon for up to COUNT commands (see processor.sh search). The
# picker's paginated windows always pass an EMPTY query — newest COUNT,
# unfiltered — and fzf's own matcher does the filtering, so this serves the
# start:reload-sync loads and the pagination reloads.
#
# Output: NUL-separated raw command rows for fzf --read0. Multi-line commands
# pass through verbatim (fzf >= 0.53 renders them natively); nothing is
# escaped. Passed through as-is.

. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

count="${1:-10000}"
query="${2:-}"
case "$count" in '' | *[!0-9]*) count=10000 ;; esac

# netstring field: "len:payload,"
_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

payload=$(printf '1:Q,%s%s%s' "$(_ns search)" "$(_ns "$query")" "$(_ns "$count")")

# Stream straight to stdout: command substitution would drop NUL bytes.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$payload" | nc -U "$KAV_SOCK_FILE" 2> /dev/null
else
    exit 0
fi
