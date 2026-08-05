#!/usr/bin/dash
# hook.sh - Called by shell hooks to record commands.
#   W CMD CWD            mint a UUIDv7 id, store the command, PRINT the id
#                        (correlation key for the later U)
#   U ID EXIT DURATION   store the real exit code and duration
# The id is the row's primary key AND timestamp (UUIDv7 sorts
# chronologically).

# Source includes.sh relative to THIS script, not CWD: hook.sh is launched
# from interactive shells whose CWD is arbitrary.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

# Netstrings are length-prefixed IN BYTES: ${#var} counts characters, which
# diverges under UTF-8 locales. Use LC_ALL=C wc -c — the same byte-accurate
# method the server's awk parser expects.
_ns_len() {
    printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

MODE="$1"
case "$MODE" in
    W)
        CMD="$2"
        CWD="$3"
        # Skip empty commands (defensive — shouldn't happen but harmless).
        [ -z "$CMD" ] && exit 0
        ID=$(kav_uuidv7)
        MSG=$(printf '1:W,%s:%s,%s:%s,%s:%s,' \
            "$(_ns_len "$CMD")" "$CMD" \
            "$(_ns_len "$CWD")" "$CWD" \
            "$(_ns_len "$ID")" "$ID")
        # Print the id before backgrounding delivery (the shell captures it
        # for the U). The backgrounded socat's stdout is /dev/null, so it
        # never holds this pipe. Only the 3-arg form prints — an extra
        # argument means the caller isn't capturing stdout.
        [ "$#" -eq 3 ] && printf '%s\n' "$ID"
        ;;
    U)
        ID="$2"
        EXIT="$3"
        DURATION="$4"
        [ -n "$ID" ] || exit 0
        [ -n "$EXIT" ] || EXIT=0
        [ -n "$DURATION" ] || DURATION=0
        MSG=$(printf '1:U,%s:%s,%s:%s,%s:%s,' \
            "$(_ns_len "$ID")" "$ID" \
            "$(_ns_len "$EXIT")" "$EXIT" \
            "$(_ns_len "$DURATION")" "$DURATION")
        ;;
    *)
        exit 1
        ;;
esac

# Fire-and-forget: backgrounded (&), stdout/stderr silenced, errors ignored.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1 &
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$KAV_SOCK_FILE" > /dev/null 2>&1 &
fi
