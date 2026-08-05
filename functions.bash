# kavkash bash integration — source from .bashrc. Self-contained: no
# bash-preexec — recording happens in precmd via bash's own PROMPT_COMMAND.

# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R.
#   count:  DB result cap (Up=500, Ctrl+R=10000)
#   init_q: initial query — Ctrl+R seeds it with the current line, Up empty
#   mode:   "walk" (Up) or "search" (Ctrl+R) — shown in the fzf prompt/header
#
# Design (fzf >= 0.54): the picker loads a *window* of the newest commands —
# start:reload-sync, one code path, no initial pipe — and fzf filters it
# in-memory as the user types: no per-keystroke DB round trips, and the full
# fzf search syntax works. picker.sh (this dir) drives pagination from fzf
# events: a `result`-event transform doubles the window when it's exhausted
# (every loaded command matches, or none do); f5 forces the next page. --sync
# resolves the cascade before the first paint, so a seeded query reaches full
# coverage in a few log2-sized round trips; --track keeps the cursor on the
# current command across reloads. The server sends raw commands — multi-line
# ones display natively (fzf >= 0.53), no escaping.
_hist_picker() {
    local count="$1" init_q="${2:-}" mode="${3:-walk}" picked key cmd win win_file
    win=$count
    (( win > 1000 )) && win=1000
    win_file=$(mktemp) || return 0
    printf '%s\n' "$win" > "$win_file"
    # NOTE: fzf's stderr must stay on the terminal (a 2>/dev/null here
    # renders a blank UI); </dev/null keeps the tty out of its stdin —
    # start:reload drives the list. print()+accept NUL-frames
    # "key\0<cmd>\0"; the awk turns that into "key\n<cmd>".
    picked=$(fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$mode> " --query "$init_q" --read0 --print0 \
        --header "$mode · $count newest · f5: older · tab: paste · enter: run" \
        --bind "start:reload-sync:$_SCRIPT_DIR/picker.sh $win_file $count load" \
        --bind "result:transform:$_SCRIPT_DIR/picker.sh $win_file $count" \
        --bind "f5:transform:$_SCRIPT_DIR/picker.sh $win_file $count force" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s\n", key, $0 }')
    rm -f "$win_file"

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

# Up: picker over the 500 newest commands (walk mode). Down is deliberately unbound.
_hist_up() { _hist_picker 500 "" walk; }

# Ctrl+R: picker seeded with the current line (search mode), 10k cap.
_hist_search() { _hist_picker 10000 "$READLINE_LINE" search; }

# Record from precmd: reading `history 1` sees every command that ran (a
# DEBUG-trap preexec would miss function-definition commands). Tradeoffs:
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

# Run it on every primary prompt via bash's PROMPT_COMMAND (array form in
# bash 5.1+, scalar before); kavkash's hook goes FIRST so $? is still the
# last command's exit status when it runs.
if [[ $(declare -p PROMPT_COMMAND 2> /dev/null) == declare\ -*a* ]]; then
    PROMPT_COMMAND=(kav_precmd_record "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="kav_precmd_record${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# bind -x runs the function directly (not just inserts text).
# Enter and Ctrl+C are NOT bound — readline's defaults execute/cancel.
#
# fzf >= 0.54 required: multi-line display (0.53), print() (0.53), transform +
# FZF_* env + result event (0.45/0.46), start:reload without an initial reader
# and the --sync render guarantee (0.54). Older fzf can't render the raw
# multi-line rows the server now sends, so the picker is disabled, not
# degraded.
_kav_fzf_ver=$(fzf --version 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$_kav_fzf_ver" ] && printf '%s\n' "$_kav_fzf_ver" | \
        awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
    bind -x '"\C-r": _hist_search'
    bind -x '"\e[A": _hist_up'
else
    printf 'kavkash: fzf >= 0.54 required (found %s) — picker disabled; Up/Ctrl-R keep shell defaults\n' \
        "${_kav_fzf_ver:-not installed}" >&2
fi
unset _kav_fzf_ver
