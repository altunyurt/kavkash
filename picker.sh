#!/bin/sh
# picker.sh - pagination helper for the fzf history picker (functions.*).
#
# Two roles:
#   picker.sh WIN_FILE COUNT load [CWD SESSION]
#                                    run query.sh with the current window
#                                    (target of the picker's start:reload-sync)
#   picker.sh WIN_FILE COUNT [force] [CWD SESSION]
#                                    decide whether the picker's window should
#                                    grow; if so, record the new size in
#                                    WIN_FILE and print a reload-sync action
#                                    for fzf's transform to run.
# CWD/SESSION scope the server query and must ride along on every reload —
# a growth-triggered reload with the wrong scope would repaint the wrong
# rows. Empty = global. fzf parses action command lines, so the widget
# single-quotes these two args (paths may contain spaces; a literal quote
# in a path is not supported).
#
# The window size lives in a temp file because fzf's transform action runs its
# command in a subshell - the widget shell can't see mutated state. Writing the
# size is the ONLY persistent side effect, which makes every decision
# idempotent: change/result events racing a reload can't double-extend.
#
# Env (exported by fzf >= 0.46 to transform commands):
#   FZF_QUERY        current query string
#   FZF_MATCH_COUNT  items matching the query
#   FZF_TOTAL_COUNT  items loaded in the window
#
# Auto-extend rule: grow when the window boundary hides matches - every loaded
# command matches (older matches may sit past the cutoff) or none do (they may
# all be older than the cutoff). An explicit `force` (bound to f5) pages
# unconditionally. The query guard keeps Up (empty query) from ballooning to
# the cap. Growth is capped at COUNT and monotonic, so the result-event
# cascade always terminates.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

win_file=$1
count=$2
mode=${3:-decide}
cwd=${4:-}
session=${5:-}
case "$count" in '' | *[!0-9]*) count=10000 ;; esac

win=$(cat "$win_file" 2> /dev/null)
case "$win" in '' | *[!0-9]*) win=1000 ;; esac

if [ "$mode" = "load" ]; then
    exec "$SCRIPT_DIR/query.sh" "$win" "" "$cwd" "$session"
fi

# decide / force: grow the window and emit a reload-sync action.
[ "$win" -lt "$count" ] || exit 0

if [ "$mode" = "force" ]; then
    grow=1
else
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
    # re-quote cwd/session: fzf re-parses this action command line
    printf "reload-sync:%s/query.sh %s '' '%s' '%s'\n" "$SCRIPT_DIR" "$win" "$cwd" "$session"
fi
