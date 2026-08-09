#!/bin/sh
# picker.sh - pagination + scope helper for the fzf history picker.
#
# Three roles (the widget builds the right argv for each):
#
#   picker.sh load WIN_FILE COUNT [SCOPE_FILE]
#       run query.sh with the current window (target of start:reload-sync
#       and of every scope switch / growth reload). CWD/SESSION come from
#       SCOPE_FILE (two lines: cwd, session; missing = global) so that a
#       scope switch and a growth-triggered reload always agree.
#
#   picker.sh decide WIN_FILE COUNT [SCOPE_FILE] [force]
#       decide whether the picker's window should grow; if so, record the
#       new size in WIN_FILE and print a reload-sync action for fzf's
#       transform to run. The action reloads through picker.sh load, which
#       re-reads WIN_FILE and SCOPE_FILE — the growth path can't diverge
#       from the scope the user is currently looking at.
#
#   picker.sh switch SCOPE_FILE CWD SESSION PROMPT WIN_FILE COUNT
#       F6/F7/F8 target: rewrite SCOPE_FILE to the new scope and print a
#       change-prompt+reload-sync action so fzf re-queries with it.
#
# The window size lives in a temp file because fzf's transform action runs
# its command in a subshell - the widget shell can't see mutated state.
# Same for the scope: transform runs picker.sh in a subshell, so the scope
# switch writes a file and the reload reads it back.
#
# Exit codes are not part of the protocol (socat EXEC and fzf transform
# both discard them); the printed action string is the contract.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mode=$1
case "$mode" in
    load)
        win_file=$2
        count=$3
        scope_file=${4:-}
        ;;
    decide)
        win_file=$2
        count=$3
        scope_file=${4:-}
        force=${5:-}
        ;;
    switch)
        scope_file=$2
        cwd=$3
        session=$4
        prompt=$5
        win_file=$6
        count=$7
        # The new scope is applied before the reload below reads it.
        printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
        # change-prompt gives the scope switch visible feedback; the
        # reload-sync re-queries through picker.sh load so win + scope
        # stay in one place. Colon form matches the decide output.
        printf 'change-prompt(%s> )+reload-sync:%s/picker.sh load %s %s %s\n' \
            "$prompt" "$SCRIPT_DIR" "$win_file" "$count" "$scope_file"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac

case "$count" in '' | *[!0-9]*) count=10000 ;; esac

win=$(cat "$win_file" 2> /dev/null)
case "$win" in '' | *[!0-9]*) win=1000 ;; esac

# Scope: two lines from SCOPE_FILE (cwd, session); unreadable = global.
# Both lines come from ONE fd — reopening between reads would get line 1
# twice (cwd leaking into session).
cwd=
session=
if [ -n "$scope_file" ] && [ -r "$scope_file" ]; then
    exec 3< "$scope_file"
    IFS= read -r cwd <&3 || true
    IFS= read -r session <&3 || true
    exec 3<&-
fi

if [ "$mode" = "load" ]; then
    exec "$SCRIPT_DIR/query.sh" "$win" "" "$cwd" "$session"
fi

# decide / force: grow the window and emit a reload-sync action (through
# picker.sh load, so win + scope stay in one place).
[ "$win" -lt "$count" ] || exit 0

if [ "$force" = "force" ]; then
    grow=1
else
    # decide mode: only grow while the user is filtering and the query
    # collapsed the loaded window (0 matches, or every row matches so
    # the newest rows are no longer in view).
    case "$FZF_QUERY" in '') exit 0 ;; esac
    case "$FZF_MATCH_COUNT" in '' | *[!0-9]*) exit 0 ;; esac
    case "$FZF_TOTAL_COUNT" in '' | *[!0-9]*) exit 0 ;; esac
    if [ "$FZF_MATCH_COUNT" -eq 0 ] || [ "$FZF_MATCH_COUNT" -ge "$FZF_TOTAL_COUNT" ]; then
        grow=1
    fi
fi

if [ -n "${grow:-}" ]; then
    win=$((win * 2))
    [ "$win" -gt "$count" ] && win=$count
    printf '%s\n' "$win" > "$win_file"
    printf 'reload-sync:%s/picker.sh load %s %s%s\n' \
        "$SCRIPT_DIR" "$win_file" "$count" "${scope_file:+ $scope_file}"
fi
