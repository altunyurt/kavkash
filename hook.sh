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

# Netstrings are length-PREFIXED IN BYTES, not characters. `${#var}` counts
# characters (locale-dependent), which under a UTF-8 locale diverges from
# byte length for any multi-byte command/path — producing a length prefix
# that doesn't match what the byte-accurate (LC_ALL=C) awk parser on the
# server expects, silently dropping the write. Use wc -c under LC_ALL=C,
# same method _write_ns uses client-side, so both ends agree.
_ns_len() {
    printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

# Build netstring message: "W,cmd,cwd,exit_code,duration" as concatenated netstrings.
# Example: 1:W,17:ls -la /home/user,10:/home/user,1:0,3:100,
MSG=$(printf '1:W,%s:%s,%s:%s,%s:%s,%s:%s,' \
    "$(_ns_len "$CMD")" "$CMD" \
    "$(_ns_len "$CWD")" "$CWD" \
    "$(_ns_len "$EXIT_CODE")" "$EXIT_CODE" \
    "$(_ns_len "$DURATION")" "$DURATION")

# Fire-and-forget delivery: backgrounded, errors suppressed.
# The trailing & detaches the process so the shell isn't blocked.
# >/dev/null 2>&1: silent on success and failure.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$SOCK_FILE" > /dev/null 2>&1 &
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$SOCK_FILE" > /dev/null 2>&1 &
fi
