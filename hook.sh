#!/usr/bin/dash
# hook.sh - Called by shell hooks to record commands.
#   W CMD CWD SESSION           mint an ns-since-epoch id, store the command
#                               (+ the caller's session token), PRINT the id
#                               (correlation key for the later U)
#   U ID EXIT DURATION [CMD]    store the real exit code and duration
#                               (the optional command pins the update to
#                               the right row — a W that bumped its id
#                               on a collision lives at a different id)
# A 5th W argument "sync" delivers in the foreground (bash's `exit` would
# kill the backgrounded socat before it connects).

# Source includes.sh relative to THIS script, not CWD: hook.sh is launched
# from interactive shells whose CWD is arbitrary.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

# Netstrings are length-prefixed IN BYTES: ${#var} counts characters, which
# diverges under UTF-8 locales.
_ns_len() {
    printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

MODE="$1"
case "$MODE" in
    W)
        CMD="$2"
        CWD="$3"
        SESSION="${4:-}"
        [ -z "$CMD" ] && exit 0
        # Shell convention: a command starting with whitespace is never
        # saved. Only the first character decides — indented continuation
        # lines of a multi-line command are unaffected.
        case "$CMD" in
            ' '* | '	'*) exit 0 ;;
        esac
        ID=$(kav_new_id)
        MSG=$(printf '1:W,%s:%s,%s:%s,%s:%s,%s:%s,' \
            "$(_ns_len "$CMD")" "$CMD" \
            "$(_ns_len "$CWD")" "$CWD" \
            "$(_ns_len "$ID")" "$ID" \
            "$(_ns_len "$SESSION")" "$SESSION")
        # Print the id before backgrounding delivery (the shell captures it
        # for the U). Only the 4-arg form prints — a 5th argument ("sync")
        # means the caller isn't capturing stdout.
        [ "$#" -eq 4 ] && printf '%s\n' "$ID"
        ;;
    U)
        ID="$2"
        EXIT="$3"
        DURATION="$4"
        CMD="${5:-}"
        [ -n "$ID" ] || exit 0
        [ -n "$EXIT" ] || EXIT=0
        [ -n "$DURATION" ] || DURATION=0
        if [ -n "$CMD" ]; then
            MSG=$(printf '1:U,%s:%s,%s:%s,%s:%s,%s:%s,' \
                "$(_ns_len "$ID")" "$ID" \
                "$(_ns_len "$EXIT")" "$EXIT" \
                "$(_ns_len "$DURATION")" "$DURATION" \
                "$(_ns_len "$CMD")" "$CMD")
        else
            MSG=$(printf '1:U,%s:%s,%s:%s,%s:%s,' \
                "$(_ns_len "$ID")" "$ID" \
                "$(_ns_len "$EXIT")" "$EXIT" \
                "$(_ns_len "$DURATION")" "$DURATION")
        fi
        ;;
    *)
        exit 1
        ;;
esac

# Fire-and-forget: backgrounded (&), stdout/stderr silenced, errors ignored.
# A 5th argument "sync" delivers in the foreground instead — bash's `exit`
# would kill the backgrounded socat before it connects, losing the row.
if command -v socat > /dev/null 2>&1; then
    if [ "$5" = sync ]; then
        printf '%s' "$MSG" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1
    else
        printf '%s' "$MSG" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1 &
    fi
elif command -v nc > /dev/null 2>&1; then
    if [ "$5" = sync ]; then
        printf '%s' "$MSG" | nc -U "$KAV_SOCK_FILE" > /dev/null 2>&1
    else
        printf '%s' "$MSG" | nc -U "$KAV_SOCK_FILE" > /dev/null 2>&1 &
    fi
fi
