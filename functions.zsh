# kavkash zsh integration — source from .zshrc.
# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=${0:A:h} # kavkash root, where hook.sh/query.sh/picker.sh live
. "$_SCRIPT_DIR/includes.sh"

# Version for the picker border label (read once per shell session).
typeset -g _hist_version=$(cat "$KAV_DATA_HOME/VERSION" 2> /dev/null || printf '?')

# Daemon liveness: every client call guards on the socket first — a dead
# daemon must never die silently (recording stops, Up/Ctrl+R do nothing).
# Warn once per outage; the flag resets as soon as the daemon is reachable
# again, so a restart mid-session re-arms the warning.
typeset -g _hist_daemon_warned=0
_hist_sock_up() {
    if [[ -S "$KAV_SOCK_FILE" ]]; then
        _hist_daemon_warned=0
        return 0
    fi
    return 1
}
_hist_warn_daemon() { # record path (preexec) — plain message
    ((_hist_daemon_warned)) && return 0
    _hist_daemon_warned=1
    printf 'kavkash: daemon not running — history is not being saved. Start it with: systemctl --user start kavkash (or run %s/server.sh &)\n' "$_SCRIPT_DIR" >&2
}
_hist_warn_daemon_widget() {            # zle widgets — leading newline so the
    ((_hist_daemon_warned)) && return 0 # redraw can't eat the message
    _hist_daemon_warned=1
    printf '\nkavkash: daemon not running — history is not being saved. Start it with: systemctl --user start kavkash (or run %s/server.sh &)\n' "$_SCRIPT_DIR" >&2
}

# _hist_picker — the single fzf widget behind Ctrl+R and F6/F7/F8 (see
# functions.bash for the design rationale; zsh mirrors it, except accept
# RUNS the picked command — zsh can from a widget).
_hist_picker() {
    local count="$1" init_q="${2:-}" cwd="${3:-}" session="${4:-}"
    local picked key cmd scope_file prompt picker header
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    if [[ -n "$cwd" ]]; then
        prompt="dir> "
    elif [[ -n "$session" ]]; then
        prompt="sess> "
    else
        prompt="search> "
    fi
    scope_file=$(mktemp) || return 0
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    picker="$_SCRIPT_DIR/picker.sh"
    header="search · F6 all F7 dir F8 sess · shift-del delete · tab paste · enter run"
    # fzf stderr must stay on the terminal (2>/dev/null blanks the UI);
    # </dev/null keeps the tty out of its stdin — start:reload drives the
    # list. count=0 = ALL distinct commands, loaded once (no window, no
    # paging); fzf filters the search text in-memory; F6-F8 re-query the
    # scope server-side via picker.sh switch. print()+accept NUL-frames
    # "key\0<cmd>\0"; awk turns that into "key\n<cmd>".
    picked=$(fzf --height 15 --no-sort --track --sync --highlight-line \
        --prompt "$prompt" --query "$init_q" --read0 --print0 \
        --delimiter $'\x1f' --with-nth 1 --accept-nth 1 \
        --header "$header" \
        --border \
        --border-label "kavkash v$_hist_version" \
        --bind "start:reload-sync:$picker load $count $scope_file" \
        --bind "shift-delete:execute-silent($_SCRIPT_DIR/delete.sh {2})+reload-sync:$picker load $count $scope_file" \
        --bind "f6:transform:$picker switch $scope_file '' '' all $count" \
        --bind "f7:transform:$picker switch $scope_file '$PWD' '' dir $count" \
        --bind "f8:transform:$picker switch $scope_file '' '$_hist_sess' sess $count" \
        --bind 'enter:print()+accept,tab:print(tab)+accept' \
        < /dev/null \
        | awk 'BEGIN { RS = "\0" }
            NR == 1 { key = $0; next }
            NR == 2 { printf "%s\n%s\n", key, $0 }')
    rm -f "$scope_file"

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

# Up/Down: walk ALL history one command per press — Up steps back one (no
# cap — the server's OFFSET on the rowid index makes deep steps cheap),
# Down steps forward and blanks the line at the bottom. The index resets
# in _hist_precmd (every new prompt), so a fresh Up always starts at the
# newest command.
typeset -g _hist_step_idx=0
_hist_step_up() {
    local cmd
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    _hist_step_idx=$((_hist_step_idx + 1))
    cmd=$("$_SCRIPT_DIR/query.sh" 1 "" "" "" $((_hist_step_idx - 1)) | tr '\0' '\n')
    cmd=${cmd%$'\x1f'*} # drop the \x1f<id> payload (Q now carries it)
    if [ -n "$cmd" ]; then
        BUFFER="$cmd"
        CURSOR=${#BUFFER}
    else
        _hist_step_idx=$((_hist_step_idx - 1)) # history exhausted — stay put
    fi
}
_hist_step_down() {
    local cmd
    if ! _hist_sock_up; then
        _hist_warn_daemon_widget
        return 0
    fi
    if ((_hist_step_idx <= 1)); then
        _hist_step_idx=0
        BUFFER=""
        CURSOR=0
        return
    fi
    _hist_step_idx=$((_hist_step_idx - 1))
    cmd=$("$_SCRIPT_DIR/query.sh" 1 "" "" "" $((_hist_step_idx - 1)) | tr '\0' '\n')
    cmd=${cmd%$'\x1f'*} # drop the \x1f<id> payload (Q now carries it)
    if [ -n "$cmd" ]; then
        BUFFER="$cmd"
        CURSOR=${#BUFFER}
    else
        _hist_step_idx=0 # defensive: the fetch came up empty
        BUFFER=""
        CURSOR=0
    fi
}

# Ctrl+R: search picker seeded with the current line (all distinct commands).
_hist_search() { _hist_picker 0 "$BUFFER"; }

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
_hist_scope_all() { _hist_picker 0 "$BUFFER" "" ""; }
_hist_scope_dir() { _hist_picker 0 "$BUFFER" "$PWD" ""; }
_hist_scope_sess() { _hist_picker 0 "$BUFFER" "" "$_hist_sess"; }

# Register widgets and bindings. Enter/Ctrl+C are NOT bound — zsh defaults
# handle them.
#
# fzf >= 0.54 required — older versions can't render the raw multi-line
# rows the server sends; the widgets are not registered.
_kav_fzf_ver=$(fzf --version 2> /dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$_kav_fzf_ver" ] && printf '%s\n' "$_kav_fzf_ver" \
    | awk -F. 'NR == 1 { exit ($1 > 0 || $2 >= 54) ? 0 : 1 }'; then
    zle -N kavkash-search _hist_search
    zle -N kavkash-step-up _hist_step_up
    zle -N kavkash-step-down _hist_step_down
    zle -N kavkash-scope-all _hist_scope_all
    zle -N kavkash-scope-dir _hist_scope_dir
    zle -N kavkash-scope-sess _hist_scope_sess

    bindkey '^R' kavkash-search
    bindkey '^[[A' kavkash-step-up
    bindkey '^[[B' kavkash-step-down
    bindkey '^[[17~' kavkash-scope-all  # F6
    bindkey '^[[18~' kavkash-scope-dir  # F7
    bindkey '^[[19~' kavkash-scope-sess # F8
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
    # Daemon down: warn (throttled); _hist_corr stays empty so precmd
    # skips the U and nothing is minted for a daemon that can't store it.
    if ! _hist_sock_up; then
        _hist_warn_daemon
        return 0
    fi
    _hist_t0=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$1" "$PWD" "$_hist_sess")
}

_hist_precmd() {
    local _hist_exit=$?
    _hist_step_idx=0 # Up/Down stepper starts fresh at every prompt
    if [ -n "$_hist_corr" ]; then
        local _now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))"
        _hist_corr=""
    fi
}

add-zsh-hook preexec _hist_preexec
add-zsh-hook precmd _hist_precmd
