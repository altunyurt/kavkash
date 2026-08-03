#!/usr/bin/dash
# hook.sh - Called by shell hooks to record commands to history.
# Two modes:
#   hook.sh W CMD CWD   preexec: mint a UUIDv7 id, store the command line,
#                       and PRINT the id — the shell keeps it as the
#                       correlation key for the later update.
#   hook.sh U ID EXIT DURATION   precmd: store the real exit code and the
#                       shell-measured duration for the pending id.
# The id is the row's primary key AND its timestamp (UUIDv7 sorts
# chronologically), so there is no separate corr/timestamp column.

# Source includes.sh relative to THIS script, not CWD: hook.sh is launched
# from interactive shells whose CWD is arbitrary.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

# Netstrings are length-PREFIXED IN BYTES, not characters. `${#var}` counts
# characters (locale-dependent), which under a UTF-8 locale diverges from
# byte length for any multi-byte command/path — producing a length prefix
# that doesn't match what the byte-accurate (LC_ALL=C) awk parser on the
# server expects, silently dropping the write. Use wc -c under LC_ALL=C,
# same method _write_ns uses client-side, so both ends agree.
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
        # Print the id BEFORE backgrounding the delivery: the shell captures
        # it as the correlation key for the precmd U. The backgrounded socat
        # gets stdout redirected to /dev/null, so it never holds this pipe.
        # Only the 3-arg protocol prints — an extra argument means the caller
        # is not capturing stdout, and printing would pollute the terminal.
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

# Fire-and-forget delivery: backgrounded, errors suppressed.
# The trailing & detaches the process so the shell isn't blocked.
# >/dev/null 2>&1: silent on success and failure.
if command -v socat > /dev/null 2>&1; then
    printf '%s' "$MSG" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" > /dev/null 2>&1 &
elif command -v nc > /dev/null 2>&1; then
    printf '%s' "$MSG" | nc -U "$KAV_SOCK_FILE" > /dev/null 2>&1 &
fi
