#!/usr/bin/dash
# hook.sh - Called by shell preexec hooks to record a command to history

# Source includes.sh relative to THIS script, not CWD: hook.sh is launched
# from interactive shells whose CWD is arbitrary.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

# Args: cmd, cwd, exit_code, duration_ms — defaults handle missing args.
CMD="$1"
CWD="$2"
EXIT_CODE="${3:-0}"
DURATION="${4:-0}"

# Skip empty commands (defensive — shouldn't happen but harmless)
[ -z "$CMD" ] && exit 0

# _ns_len - netstring length prefix is IN BYTES. ${#var} counts chars
# (locale-dependent), so UTF-8 multi-byte commands would produce a length
# prefix that mismatches the byte-accurate (LC_ALL=C) awk parser server-side,
# silently dropping the write. Use wc -c under LC_ALL=C, same as client-side.
_ns_len() {
    printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

# Build write message: "W,cmd,cwd,exit_code,duration" as concatenated
# netstrings. Example: 1:W,17:ls -la /home/user,10:/home/user,1:0,3:100,
MSG=$(printf '1:W,%s:%s,%s:%s,%s:%s,%s:%s,' \
    "$(_ns_len "$CMD")" "$CMD" \
    "$(_ns_len "$CWD")" "$CWD" \
    "$(_ns_len "$EXIT_CODE")" "$EXIT_CODE" \
    "$(_ns_len "$DURATION")" "$DURATION")

# Fire-and-forget: backgrounded, silent — the shell isn't blocked and
# write failures (daemon down) produce no noise.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1 &
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$KAV_SOCK_FILE" > /dev/null 2>&1 &
fi
