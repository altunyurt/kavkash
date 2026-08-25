#!/bin/sh
# picker.sh - scope helper for the fzf history picker.
#   load COUNT [SCOPE_FILE [WIDTH]]  query.sh for the whole distinct set,
#                                target of reload-sync (start + every
#                                scope switch). CWD/SESSION come from
#                                SCOPE_FILE (two lines; missing = global).
#                                WIDTH = terminal columns: the command
#                                display column is padded/truncated to it
#                                so the metadata stays on one line and
#                                aligns (0 = no transform).
#   switch SCOPE_FILE CWD SESSION PROMPT COUNT WIDTH
#                                F6/F7/F8 target: rewrite SCOPE_FILE,
#                                print change-prompt+reload-sync.
# The scope lives in a temp file because fzf runs the transform in a
# subshell — the widget shell can't see mutated state. Exit codes are
# not part of the protocol; the printed action string is the contract.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mode=$1
case "$mode" in
    load)
        count=$2
        scope_file=${3:-}
        width=${4:-0}
        ;;
    switch)
        scope_file=$2
        cwd=$3
        session=$4
        prompt=$5
        count=$6
        width=${7:-0}
        # The new scope is applied before the reload below reads it.
        printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
        printf 'change-prompt(%s> )+reload-sync:%s/picker.sh load %s %s %s\n' \
            "$prompt" "$SCRIPT_DIR" "$count" "$scope_file" "$width"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac

case "$count" in '' | *[!0-9]*) count=0 ;; esac
case "$width" in '' | *[!0-9]*) width=0 ;; esac

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

# Tabular transform: rows are "command\x1d meta\x1fid" — rebuilt as
# "display\x1d meta\x1f full \x1f id". display = the command padded or
# truncated (… marks truncation) to WIDTH, so the trailing metadata
# column aligns and never wraps. The FULL command rides in field 2:
# fzf accepts what it displays, so the truncated text must not be what
# gets accepted — matching also sees field 2, so text beyond the
# truncation point still matches. Multi-line commands keep their native
# display (truncating them would destroy their structure). gawk under a
# UTF-8 locale counts characters (correct column width); mawk or a C
# locale counts bytes — truncation still works, the column drifts only
# on multibyte commands.
if command -v gawk > /dev/null 2>&1; then
    AWK=gawk
else
    AWK=awk
fi
"$SCRIPT_DIR/query.sh" "$count" "" "$cwd" "$session" | "$AWK" -v W="$width" '
BEGIN { RS = "\0" }
{
    row = $0
    if (row == "") next
    i = index(row, "\035")            # command \x1d meta \x1f id
    if (i == 0) { printf "%s\036", row; next }
    full = substr(row, 1, i - 1)
    rest = substr(row, i + 1)
    j = index(rest, "\037")
    if (j == 0) { printf "%s\036", row; next }
    meta = substr(rest, 1, j - 1)
    id = substr(rest, j + 1)
    disp = full
    if (W > 0 && index(full, "\n") == 0) {
        if (length(full) > W - 1) disp = substr(full, 1, W - 1) "…"
        else while (length(disp) < W) disp = disp " "
    }
    printf "%s\035%s\037%s\037%s\036", disp, meta, full, id
}' | tr '\036' '\000'
