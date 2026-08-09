# kavkash zsh integration — source from .zshrc.
# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=${0:A:h}      # kavkash root, where hook.sh/query.sh/picker.sh live
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale; zsh mirrors it, except accept
# RUNS the picked command — zsh can from a widget).
_hist_picker() {
    local count="$1" init_q="${2:-}" mode="${3:-walk}" cwd="${4:-}" session="${5:-}"
    local picked key cmd win win_file scope_file label prompt picker
    if [[ -n "$cwd" ]]; then
        label="dir $cwd"; prompt="dir> "
    elif [[ -n "$session" ]]; then
        label="session"; prompt="sess> "
    else
        label="all"; prompt="$mode> "
    fi
    win=$count
    (( win > 1000 )) && win=1000
    win_file=$(mktemp) || return 0
    scope_file=$(mktemp) || {
        rm -f "$win_file"
        return 0
    }
    printf '%s\n' "$win" > "$win_file"
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    picker="$_SCRIPT_DIR/picker.sh"
    # NOTE: fzf's stderr must stay on the terminal (a 2>/dev/null here
    # renders a blank UI); </dev/null keeps the tty out of its stdin —
    # start:reload drives the list. print()+accept NUL-frames
    # "key\0<cmd>\0"; the awk turns that into "key\n<cmd>".
    # Scope lives in SCOPE_FILE; every reload goes through picker.sh load
    # (start, growth, F5, F6-F8), so win and scope never diverge. F6/F7/F8
    # switch scope inside the picker via picker.sh switch.
    picked=$(fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --header "$mode · $count newest · $label · F6 all F7 dir F8 sess · f5 older · tab paste · enter run" \
        --bind "start:reload-sync:$picker load $win_file $count $scope_file" \
        --bind "result:transform:$picker decide $win_file $count $scope_file" \
        --bind "f5:transform:$picker decide $win_file $count $scope_file force" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $win_file $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $win_file $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $win_file $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s\n", key, $0 }')
    rm -f "$win_file" "$scope_file"

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

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
_hist_scope_all() { _hist_picker 10000 "$BUFFER" search "" ""; }
_hist_scope_dir() { _hist_picker 10000 "$BUFFER" search "$PWD" ""; }
_hist_scope_sess() { _hist_picker 10000 "$BUFFER" search "" "$_hist_sess"; }

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
    zle -N kavkash-scope-all _hist_scope_all
    zle -N kavkash-scope-dir _hist_scope_dir
    zle -N kavkash-scope-sess _hist_scope_sess

    bindkey '^R' kavkash-search
    bindkey '^[[A' kavkash-up
    bindkey '^[[17~' kavkash-scope-all   # F6
    bindkey '^[[18~' kavkash-scope-dir   # F7
    bindkey '^[[19~' kavkash-scope-sess  # F8
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

# Session token: one per interactive shell, minted at source time (rc files
# re-run on `exec`, so the new shell gets a fresh token — never inherit).
# Carried on every W; session scope in the picker matches on it.
typeset -g _hist_sess=$(cat /proc/sys/kernel/random/uuid 2> /dev/null) || _hist_sess=$(od -An -N16 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')

_hist_preexec() {
    _hist_t0=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$1" "$PWD" "$_hist_sess")
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
