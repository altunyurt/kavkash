#!/usr/bin/dash
# hook.sh - Called by shell hooks to record commands to history.
# Two modes:
#   hook.sh W CMD CWD CORR   preexec: store the command line (exit unknown yet)
#   hook.sh U CORR EXIT      precmd:  store the real exit code for corr
# CORR is a per-command-line key (shell pid + per-shell counter) that pairs
# the precmd update with the preexec row — see processor.sh U case.

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
        CORR="$4"
        # Skip empty commands (defensive — shouldn't happen but harmless)
        [ -z "$CMD" ] && exit 0
        MSG=$(printf '1:W,%s:%s,%s:%s,%s:%s,' \
            "$(_ns_len "$CMD")" "$CMD" \
            "$(_ns_len "$CWD")" "$CWD" \
            "$(_ns_len "$CORR")" "$CORR")
        ;;
    U)
        CORR="$2"
        EXIT="$3"
        [ -n "$CORR" ] || exit 0
        [ -n "$EXIT" ] || EXIT=0
        MSG=$(printf '1:U,%s:%s,%s:%s,' \
            "$(_ns_len "$CORR")" "$CORR" \
            "$(_ns_len "$EXIT")" "$EXIT")
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
