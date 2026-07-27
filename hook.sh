#!/usr/bin/dash
# hook.sh - Called by shell preexec hooks to record a command to history

SOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/history.sock"

# Args: cmd, cwd, exit_code, duration_ms
# Defaults handle missing args (e.g. preexec fires before postexec for first run)
CMD="$1"
CWD="$2"
EXIT_CODE="${3:-0}"
DURATION="${4:-0}"

# Skip empty commands (defensive — shouldn't happen but harmless)
[ -z "$CMD" ] && exit 0

# Build netstring message in a single printf call.
# Format: "W,cmd,cwd,exit_code,duration" as concatenated netstrings.
# Example: 1:W,17:ls -la /home/user,10:/home/user,1:0,3:100,
# %d = byte length, %s = payload — printf does the length calculation.
# One subshell total (was 5 before optimization).
MSG=$(printf '1:W,%d:%s,%d:%s,%d:%s,%d:%s,' \
    "${#CMD}" "$CMD" \
    "${#CWD}" "$CWD" \
    "${#EXIT_CODE}" "$EXIT_CODE" \
    "${#DURATION}" "$DURATION")

# Fire-and-forget delivery: backgrounded, errors suppressed.
# The trailing & detaches the process so the shell isn't blocked.
# >/dev/null 2>&1: silent on success and failure.
if command -v socat >/dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$SOCK_FILE" >/dev/null 2>&1 &
elif command -v nc >/dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$SOCK_FILE" >/dev/null 2>&1 &
fi
