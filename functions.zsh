# kavkash zsh integration — source from .zshrc.
# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=${0:A:h}      # kavkash root, where hook.sh/query.sh live
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind both Up and Ctrl+R (see
# functions.bash for the design rationale; zsh mirrors it, except accept
# RUNS the picked command — zsh can from a widget).
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

    BUFFER="$cmd"
    CURSOR=${#BUFFER}
    if [[ -z "$key" ]]; then
        # Enter: paste and run.
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
