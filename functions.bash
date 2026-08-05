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
# Live list: the initial pipe plus a debounced change:reload (sleep 0.1;
# fzf kills the previous reload per keystroke, so only a query stable for
# 100ms hits the DB). --disabled makes fzf a pure selector — the DB query
# IS the filter. The server display-escapes embedded newlines (\n,
# backslashes doubled) so multi-line commands render on one line.
_hist_picker() {
    local count="$1" init_q="${2:-}" picked key cmd
    # NOTE: fzf's stderr must stay connected to the terminal. Inside a
    # command substitution stdout is a pipe, so fzf falls back to stderr
    # (then /dev/tty) for its UI — a `2>/dev/null` here makes the picker
    # render nothing and appear stuck.
    # --expect=tab prefixes the output with the accepting key ("tab" or
    # empty for Enter), NUL-framed; the awk turns that into "key\n<decoded
    # command>" — reversing the server's \n / \\ display escaping — for
    # the shell to split.
    picked=$("$_SCRIPT_DIR/query.sh" "$count" "$init_q" | fzf \
        --disabled --height 15 --no-sort --prompt 'history> ' \
        --query "$init_q" --read0 --print0 --expect=tab \
        --bind "change:reload:sleep 0.1; $_SCRIPT_DIR/query.sh $count {q}" \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 {
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
                printf "%s\n%s\n", key, o
            }')

    [ -z "$picked" ] && return 0
    key="${picked%%$'\n'*}"
    cmd="${picked#*$'\n'}"
    [ -z "$cmd" ] && return 0

    if [[ -z "$key" ]]; then
        # Enter: paste and run. readline can't accept the line from a
        # widget, so record it (history -s, so Up-arrow still sees it) and
        # eval it directly. A new prompt is NOT displayed after a bind -x
        # callback, so precmd never runs — record here via hook.sh instead.
        history -s "$cmd"
        READLINE_LINE=""
        local _hist_exit
        eval "$cmd"
        _hist_exit=$?
        local id
        id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD")
        if [[ -n "$id" ]]; then
            "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
        fi
        _hist_last="$cmd"   # same consecutive-dup dedup as the precmd path
    else
        # Tab: paste onto the line; Enter will run it (and precmd records).
        READLINE_LINE="$cmd"
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# Up: picker over the 500 newest commands. Down is deliberately unbound.
_hist_up() { _hist_picker 500 ""; }

# Ctrl+R: picker seeded with the current line, 10k cap.
_hist_search() { _hist_picker 10000 "$READLINE_LINE"; }

# Record from precmd ONLY: bash-preexec's preexec (DEBUG trap) never fires
# for function-definition commands, so it would miss `f() { ... }`.
# Reading `history 1` in precmd sees every command that ran. Tradeoffs:
# duration is always 0; `exit` and leading-space commands never enter bash
# history, so they aren't recorded; consecutive duplicates are dedup'd by
# bash itself plus the _hist_last guard.
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
