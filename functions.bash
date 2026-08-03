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
# The server renders embedded newlines as ⏎ for single-line display; on
# accept we reverse that so multi-line commands round-trip intact.
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

# Record executed commands. preexec mints the correlation id (hook.sh prints
# it) and captures the start time; precmd reports exit + shell-measured
# duration for that id (see processor.sh U).
_hist_corr=""
_hist_t0=0

preexec_hook() {
    _hist_t0=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$1" "$PWD")
}
preexec_functions+=(preexec_hook)

# precmd: report the finished line's exit code and duration. bash-preexec
# restores the real $? before invoking each precmd function
# (__bp_set_ret_value in bash-preexec.sh), so capturing it first is safe.
precmd_hist_report() {
    local _hist_exit=$?
    if [[ -n $_hist_corr ]]; then
        local _now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))"
        _hist_corr=""
    fi
}
precmd_functions+=(precmd_hist_report)

# bind -x runs the function directly (not just inserts text).
# Enter and Ctrl+C are NOT bound — readline's defaults execute/cancel.
bind -x '"\C-r": _hist_search'
bind -x '"\e[A": _hist_up'
