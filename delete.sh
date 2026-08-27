#!/bin/sh
# delete.sh ID — permanently delete a command (all its occurrences) via
# the daemon. The picker's shift-delete binding feeds it the row id from
# the Q response; unknown ids delete nothing.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

id="$1"
case "$id" in '' | *[!0-9]*) exit 0 ;; esac

# netstring: "len:payload," (len in BYTES — LC_ALL=C wc -c, not ${#x})
payload=$(printf '1:D,%s:%s,' "$(printf '%s' "$id" | LC_ALL=C wc -c | tr -d ' ')" "$id")

if command -v socat > /dev/null 2>&1; then
    printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1
fi
