# kavkash bash integration — source from .bashrc.
# Requires bash-preexec.

if [[ -z "${bash_preexec_imported:-}" ]]; then
    printf "Bash-preexec is NOT loaded. If you don't have bash-preexec installed yet, visit"
    printf "\n    https://github.com/rcaloras/bash-preexec\n"
    printf "for installation instructions"
    exit 1
fi

# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R.
#   count:  DB result cap (Up=500, Ctrl+R=10000)
#   init_q: initial query — Ctrl+R seeds it with the current line, Up empty
# The list is loaded live from the daemon: the initial pipe plus a debounced
# change:reload (sleep 0.1; fzf kills the previous reload on each keystroke,
# so only a query that stays stable for 100ms actually hits the DB).
# --disabled turns fzf into a pure selector — the DB query IS the filter.
# The server emits NUL-terminated rows with embedded newlines kept raw, so
# multi-line commands display as-is and round-trip intact (fzf --read0/
# --print0; the terminator is stripped with tr before readline sees it).
_hist_picker() {
    local count="$1" init_q="${2:-}" selected
    # NOTE: fzf's stderr must stay connected to the terminal. Inside a
    # command substitution stdout is a pipe, so fzf falls back to stderr
    # (then /dev/tty) for its UI — a `2>/dev/null` here makes the picker
    # render nothing and appear stuck.
    # NUL-framed rows: fzf --read0/--print0; tr strips the terminator. The
    # server display-escaped newlines (\n) and doubled backslashes (\\), so
    # a single-pass awk undoes exactly that pair — any other backslash
    # sequence passes through untouched, keeping the round-trip lossless.
    selected=$("$_SCRIPT_DIR/query.sh" "$count" "$init_q" | fzf \
        --disabled --height 15 --no-sort --prompt 'history> ' \
        --query "$init_q" --read0 --print0 \
        --bind "change:reload:sleep 0.1; $_SCRIPT_DIR/query.sh $count {q}" \
        | tr -d '\0' | awk '{
            s = $0; o = ""; n = length(s); i = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\" && i < n) {
                    c2 = substr(s, i + 1, 1)
                    if (c2 == "\\") { o = o "\\"; i += 2; continue }
                    if (c2 == "n")  { o = o "\n"; i += 2; continue }
                }
                o = o c; i++
            }
            printf "%s", o }')

    if [[ -n "$selected" ]]; then
        # accept-then-Enter: readline can't run the line from a widget, so
        # the picked command lands on the line and Enter executes it.
        READLINE_LINE="$selected"
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# Up: picker over the 500 newest commands. Down is deliberately unbound.
_hist_up() { _hist_picker 500 ""; }

# Ctrl+R: picker seeded with the current line, 10k cap.
_hist_search() { _hist_picker 10000 "$READLINE_LINE"; }

# Record executed commands from precmd ONLY. bash-preexec's preexec is
# built on the DEBUG trap, which bash never fires for function-definition
# commands — so a preexec-based recorder can't see `f() { ... }` at all.
# Reading `history 1` in precmd sees every command that actually ran, with
# the real exit code (bash-preexec restores $? before each precmd function
# via __bp_set_ret_value).
# Tradeoffs vs preexec: duration is 0 (no reliable pre-command hook exists
# for every command form); `exit`/`logout` aren't recorded (no prompt
# after); commands starting with a space never enter bash history
# (HISTCONTROL=ignoreboth) so they aren't recorded either. Repeated
# identical commands are also dedup'd by bash history itself (ignoreboth)
# plus the _hist_last guard below.
_hist_last=""

kav_precmd_record() {
    local _hist_exit=$?    # capture FIRST — anything else clobbers it
    local cmd
    cmd=$(HISTTIMEFORMAT='' builtin history 1)
    cmd="${cmd#*[[:digit:]][* ] }"
    # blank-prompt Enter leaves history unchanged — dedup skips it
    [[ -n "$cmd" && "$cmd" != "$_hist_last" ]] || return 0
    _hist_last="$cmd"
    local id
    id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD")
    [[ -n "$id" ]] || return 0
    "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
}
precmd_functions+=(kav_precmd_record)

# bind -x runs the function directly (not just inserts text).
# Enter and Ctrl+C are NOT bound — readline's defaults execute/cancel.
bind -x '"\C-r": _hist_search'
bind -x '"\e[A": _hist_up'
