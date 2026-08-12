#!/bin/sh
# picker.sh - scope helper for the fzf history picker. Two roles (the
# widget builds the right argv for each):
#
#   picker.sh load COUNT [SCOPE_FILE]
#       run query.sh for the whole distinct set (COUNT=0 = no limit);
#       target of start:reload-sync and of every scope-switch reload.
#       CWD/SESSION come from SCOPE_FILE (two lines: cwd, session;
#       missing = global).
#
#   picker.sh switch SCOPE_FILE CWD SESSION PROMPT COUNT
#       F6/F7/F8 target: rewrite SCOPE_FILE to the new scope, then print
#       change-prompt+reload-sync so fzf re-queries with it.
#
# The scope lives in a temp file because fzf's transform runs its command
# in a subshell — the widget shell can't see mutated state. Exit codes
# are not part of the protocol (socat EXEC and fzf transform discard
# them); the printed action string is the contract.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mode=$1
case "$mode" in
    load)
        count=$2
        scope_file=${3:-}
        ;;
    switch)
        scope_file=$2
        cwd=$3
        session=$4
        prompt=$5
        count=$6
        # The new scope is applied before the reload below reads it.
        printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
        # change-prompt gives the scope switch visible feedback; the
        # reload-sync re-queries through picker.sh load so the scope
        # never diverges.
        printf 'change-prompt(%s> )+reload-sync:%s/picker.sh load %s %s\n' \
            "$prompt" "$SCRIPT_DIR" "$count" "$scope_file"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac

case "$count" in '' | *[!0-9]*) count=0 ;; esac

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

exec "$SCRIPT_DIR/query.sh" "$count" "" "$cwd" "$session"
