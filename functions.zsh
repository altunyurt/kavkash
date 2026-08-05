# kavkash zsh integration — source from .zshrc.
# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=${0:A:h}      # kavkash root, where hook.sh/query.sh/picker.sh live
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale; zsh mirrors it, except accept
# RUNS the picked command — zsh can from a widget).
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

    # fzf ran as a full-screen app inside this widget; zle's incremental
    # redraw won't repaint the prompt it clobbered. Force a full repaint.
    zle reset-prompt

    [ -z "$picked" ] && return 0
    key="${picked%%$'\n'*}"
    cmd="${picked#*$'\n'}"
    [ -z "$cmd" ] && return 0

    BUFFER="$cmd"
    CURSOR=${#BUFFER}
    if [[ -z "$key" ]]; then
        # Enter: paste and run.
        zle accept-line
    fi
    return 0
}

# Up: picker over the 500 newest commands (walk mode). Down is left at zsh's default.
_hist_up() { _hist_picker 500 "" walk; }

# Ctrl+R: picker seeded with the current line (search mode), 10k cap.
_hist_search() { _hist_picker 10000 "$BUFFER" search; }

# Register widgets and bindings. Enter/Ctrl+C are NOT bound — zsh defaults
# handle them.
#
# fzf >= 0.54 required: multi-line display (0.53), print() (0.53), transform +
# FZF_* env + result event (0.45/0.46), start:reload without an initial reader
# and the --sync render guarantee (0.54). Older fzf can't render the raw
# multi-line rows the server now sends, so the widgets are not registered.
_kav_fzf_ver=$(fzf --version 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$_kav_fzf_ver" ] && printf '%s\n' "$_kav_fzf_ver" | \
        awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
    zle -N kavkash-search _hist_search
    zle -N kavkash-up _hist_up

    bindkey '^R' kavkash-search
    bindkey '^[[A' kavkash-up
else
    printf 'kavkash: fzf >= 0.54 required (found %s) — picker disabled; Up/Ctrl-R keep shell defaults\n' \
        "${_kav_fzf_ver:-not installed}" >&2
fi
unset _kav_fzf_ver

# Record: zsh's preexec fires for every command line (incl. multiline
# function definitions, unlike bash's DEBUG trap) and mints the correlation
# id + start time; precmd reports exit + duration for that id ($? captured
# FIRST). Record $1 (as typed, newlines intact) — $2 is zsh's re-rendered
# form, which abbreviates function bodies as `g8 () { ... }`.
autoload -Uz add-zsh-hook

typeset -g _hist_corr=""
typeset -g _hist_t0=0

_hist_preexec() {
    _hist_t0=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$1" "$PWD")
}

_hist_precmd() {
    local _hist_exit=$?
    if [ -n "$_hist_corr" ]; then
        local _now=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))"
        _hist_corr=""
    fi
}

add-zsh-hook preexec _hist_preexec
add-zsh-hook precmd _hist_precmd
