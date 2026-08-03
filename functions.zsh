# kavkash zsh integration — source from .zshrc.
# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=${0:A:h}      # kavkash root, where hook.sh/query.sh live
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale; zsh mirrors it, except accept
# RUNS the picked command — zsh can from a widget).
_hist_picker() {
    local count="$1" init_q="${2:-}" selected
    # NOTE: fzf's stderr must stay connected to the terminal. Inside a
    # command substitution stdout is a pipe, so fzf falls back to stderr
    # (then /dev/tty) for its UI — a `2>/dev/null` here makes the picker
    # render nothing and appear stuck.
    selected=$("$_SCRIPT_DIR/query.sh" "$count" "$init_q" | fzf \
        --disabled --height 15 --no-sort --prompt 'history> ' \
        --query "$init_q" \
        --bind "change:reload:sleep 0.1; $_SCRIPT_DIR/query.sh $count {q}" \
        | awk '{ gsub("⏎", "\n"); print }')

    if [[ -n "$selected" ]]; then
        BUFFER="$selected"
        CURSOR=${#BUFFER}
        # one Enter both accepts and runs (zsh/fish decision; bash keeps the
        # two-Enter accept-then-run because readline widgets can't execute).
        zle accept-line
    fi
    return 0
}

# Up: picker over the 500 newest commands. Down is left at zsh's default.
_hist_up() { _hist_picker 500 ""; }

# Ctrl+R: picker seeded with the current line, 10k cap.
_hist_search() { _hist_picker 10000 "$BUFFER"; }

# Register widgets and bindings. Enter/Ctrl+C are NOT bound — zsh defaults
# handle them.
zle -N kavkash-search _hist_search
zle -N kavkash-up _hist_up

bindkey '^R' kavkash-search
bindkey '^[[A' kavkash-up

# Record executed commands: preexec mints the correlation id (hook.sh prints
# it) and captures the start time; precmd reports exit + shell-measured
# duration for that id (see processor.sh U). $? is captured FIRST in precmd
# before anything else can clobber it.
autoload -Uz add-zsh-hook

typeset -g _hist_corr=""
typeset -g _hist_t0=0

_hist_preexec() {
    _hist_t0=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "${2:-$1}" "$PWD")
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
