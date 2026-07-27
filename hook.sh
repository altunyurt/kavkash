#!/usr/bin/dash
# hook.sh - Netstring protocol emitter
SOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/history.sock"

# Parameters passed from shell hooks
CMD="$1"
CWD="$2"
EXIT_CODE="$3"
DURATION="$4"

[ -z "$CMD" ] && exit 0

# Write netstring: length:payload,
write_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

# Encode fields
NS_CMD=$(write_ns "$CMD")
NS_CWD=$(write_ns "$CWD")
NS_EXIT=$(write_ns "${EXIT_CODE:-0}")
NS_DUR=$(write_ns "${DURATION:-0}")

# Build message: W, cmd, cwd, exit_code, duration
MSG="1:W,${NS_CMD}${NS_CWD}${NS_EXIT}${NS_DUR}"

# Asynchronous non-blocking push to Unix domain socket
if command -v socat >/dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$SOCK_FILE" >/dev/null 2>&1 &
elif command -v nc >/dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$SOCK_FILE" >/dev/null 2>&1 &
fi
