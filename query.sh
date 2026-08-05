#!/bin/sh
# query.sh COUNT [QUERY] — history picker back-end.
#
# Asks the daemon for up to COUNT commands whose text subsequence-matches
# every whitespace-separated term of QUERY (see processor.sh search).
# Serves the picker's initial pipe and its change:reload target.
#
# Output: NUL-separated command rows for fzf --read0. The server
# display-escapes embedded newlines (\n, backslashes doubled) so each
# command renders on one line; the picker clients reverse that pair on
# accept. Passed through as-is.

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
