#!/bin/sh
# query.sh COUNT [QUERY] — history picker back-end.
#
# Queries the daemon for up to COUNT commands whose text contains every
# whitespace-separated term of QUERY as a subsequence (the server expands
# each term into a LIKE pattern; see processor.sh search). Serves two roles:
#   - the fzf picker's initial pipe (functions.bash/.fish/.zsh)
#   - the picker's change:reload target on every keystroke
#
# Output: NUL-separated command rows, framed for fzf --read0. The server
# keeps embedded newlines raw (NUL can't appear in command text, so the
# framing is unambiguous) and strips the sqlite3 -ascii framing hazards
# (0x1E/0x1F) plus \r. No encoding on either side — the response is passed
# through as-is.

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

# The NUL-framed response must not pass through a command substitution —
# shells drop NUL bytes in $(...) — so it is streamed straight to stdout.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$payload" | nc -U "$KAV_SOCK_FILE" 2> /dev/null
else
    exit 0
fi
