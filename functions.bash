# kavkash bash integration — source from .bashrc. Self-contained: no
# bash-preexec — recording is a DEBUG-trap preexec + PROMPT_COMMAND.

# Shared paths from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# _hist_picker — the single fzf widget behind Up, Ctrl+R and the scope
# keys (F6 all / F7 dir / F8 session — search mode with a scope).
#   count:    DB result cap (Up=500, Ctrl+R=10000)
#   init_q:   initial query — Ctrl+R seeds it with the current line, Up empty
#   mode:     "walk" (Up) or "search" (Ctrl+R) — shown in the fzf prompt/header
#   cwd:      dir scope (empty = global) — matches the dir and its subtree
#   session:  per-shell token scope (empty = global)
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
# ones display natively (fzf >= 0.53), no escaping. Scope filters are
# server-side (before the LIMIT), so a dir/session command from long ago
# isn't cut off by the window; fzf still does the keyword filtering.
_hist_picker() {
    local count="$1" init_q="${2:-}" mode="${3:-walk}" cwd="${4:-}" session="${5:-}"
    local picked key cmd win win_file scope_file label prompt picker
    _hist_armed=0   # the trap fires for the bind -x widget invocation itself
                    # and for the eval'd Enter command — both must not record
    if [[ -n "$cwd" ]]; then
        label="dir $cwd"; prompt="dir> "
    elif [[ -n "$session" ]]; then
        label="session"; prompt="sess> "
    else
        label="all"; prompt="$mode> "
    fi
    win=$count
    (( win > 1000 )) && win=1000
    win_file=$(mktemp) || {
        _hist_armed=1
        return 0
    }
    scope_file=$(mktemp) || {
        rm -f "$win_file"
        _hist_armed=1
        return 0
    }
    printf '%s\n' "$win" > "$win_file"
    printf '%s\n%s\n' "$cwd" "$session" > "$scope_file"
    picker="$_SCRIPT_DIR/picker.sh"
    # NOTE: fzf's stderr must stay on the terminal (a 2>/dev/null here
    # renders a blank UI); </dev/null keeps the tty out of its stdin —
    # start:reload drives the list. print()+accept NUL-frames
    # "key\0<cmd>\0"; the awk turns that into "key\n<cmd>".
    # Scope lives in SCOPE_FILE; every reload (start, growth, F5, F6-F8)
    # goes through picker.sh load so win and scope never diverge.
    # F6/F7/F8 switch scope inside the picker via picker.sh switch, which
    # rewrites the scope file and prints the reload action for transform.
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

    if [[ -n "$picked" ]]; then
        key="${picked%%$'\n'*}"
        cmd="${picked#*$'\n'}"
        if [[ -n "$cmd" ]]; then
            if [[ -z "$key" ]]; then
                # Enter: paste and run. readline can't accept the line from
                # a widget, so record it (history -s, so Up-arrow still
                # sees it) and eval it directly. The DEBUG preexec is
                # disarmed for this whole widget, so the eval'd command
                # doesn't self-record; hook.sh does W here and U right
                # after with the real exit code.
                history -s "$cmd"
                READLINE_LINE=""
                local _hist_exit
                eval "$cmd"
                _hist_exit=$?
                local id
                id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
                if [[ -n "$id" ]]; then
                    "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
                fi
                # precmd won't run for this line (bind -x callbacks don't
                # re-display the prompt), so sync the index baseline.
                _hist_last_idx=$(_kav_hist_idx)
            else
                # Tab: paste onto the line; Enter will run it (and precmd
                # records).
                READLINE_LINE="$cmd"
                READLINE_POINT=${#READLINE_LINE}
            fi
        fi
    fi
    _hist_armed=1   # re-arm on every exit path: the next typed line records again
}

# Up: picker over the 500 newest commands (walk mode). Down is deliberately unbound.
_hist_up() { _hist_picker 500 "" walk; }

# Ctrl+R: picker seeded with the current line (search mode), 10k cap.
_hist_search() { _hist_picker 10000 "$READLINE_LINE" search; }

# Scope variants: F6 all, F7 current dir (+subtree), F8 this shell session.
_hist_scope_all() { _hist_picker 10000 "$READLINE_LINE" search "" ""; }
_hist_scope_dir() { _hist_picker 10000 "$READLINE_LINE" search "$PWD" ""; }
_hist_scope_sess() { _hist_picker 10000 "$READLINE_LINE" search "" "$_hist_sess"; }

# --- capture: preexec (DEBUG trap) + precmd (PROMPT_COMMAND) ---
#
# bash has no preexec event, so kavkash synthesizes one with a DEBUG trap
# (the same trick bash-preexec uses). Empirically, in interactive bash:
#   - the trap fires before EVERY simple command, but NOT recursively (no
#     re-entry for commands inside the trap body) and NOT in subshells
#   - it fires once per simple command of a line (`a && b` twice) and for
#     commands in PROMPT_COMMAND — filtered by the history-index check
#   - it fires for bind -x widget invocations (e.g. the picker) — filtered
#     the same way, since history doesn't grow
#   - it does NOT fire for function definitions — but the PROMPT_COMMAND
#     fire at the next prompt sees the history growth and records the line
#     then (real exit code, prompt-sized duration); the precmd fallback
#     below is only the safety net
#   - leading-space commands never reach history (HISTCONTROL=ignorespace)
#     and BASH_COMMAND only holds the current simple command, so they can't
#     be captured with the full line — documented limitation
#
# Two guards:
#   _hist_armed — set ONLY at the end of PROMPT_COMMAND, so startup files
#                 (where history is not even loaded yet) and the first
#                 prompt can't fire. After the first prompt it stays armed
#                 across prompt redraws; a real command consumes it.
#   index check — a fire only records when history has actually grown past
#                 the last recorded entry. That kills bind -x widgets,
#                 PROMPT_COMMAND's own commands, and blank Enters without
#                 needing to know which command is which.
_hist_armed=0
_hist_initialized=0
_hist_corr=""
_hist_t0=0
_hist_last_idx=0

_kav_hist_idx() {
    HISTTIMEFORMAT='' builtin history 1 | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

kav_preexec_record() {
    (( _hist_armed )) || return 0
    local line idx cmd
    line=$(HISTTIMEFORMAT='' builtin history 1)
    idx=$(_kav_hist_idx)
    [[ "$idx" =~ ^[0-9]+$ ]] || return 0
    (( idx > _hist_last_idx )) || return 0   # bind -x widget / prompt noise
    cmd="${line#*[[:digit:]][* ] }"
    [[ -n "$cmd" ]] || return 0
    _hist_last_idx=$idx
    _hist_armed=0
    if [[ "$cmd" == "exit" || "$cmd" == "logout" ]]; then
        # The shell exits before a backgrounded delivery could connect,
        # so the last command would be lost — send this one synchronously.
        "$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess" sync
        return 0
    fi
    _hist_t0=$(date +%s%3N 2> /dev/null || date +%s)
    _hist_corr=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
}

kav_precmd_record() {
    local _hist_exit=$?    # capture FIRST — anything else clobbers it
    if [[ -n "$_hist_corr" ]]; then
        local _now=$(date +%s%3N 2> /dev/null || date +%s)
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit" "$((_now - _hist_t0))"
        _hist_corr=""
    fi
    # Baseline the history index on the first prompt: history is loaded
    # only after the rc files, so entries that predate sourcing must not
    # be treated as new. After that, the prompt's own DEBUG fire already
    # consumed any growth (function definitions); this fallback records
    # whatever slipped through, exit code included, duration unknown (0).
    local line idx cmd
    line=$(HISTTIMEFORMAT='' builtin history 1)
    idx=$(_kav_hist_idx)
    if (( _hist_initialized )); then
        cmd="${line#*[[:digit:]][* ] }"
        if [[ "$idx" =~ ^[0-9]+$ && $idx -gt _hist_last_idx && -n "$cmd" ]]; then
            _hist_last_idx=$idx
            local id
            id=$("$_SCRIPT_DIR/hook.sh" W "$cmd" "$PWD" "$_hist_sess")
            [[ -n "$id" ]] && "$_SCRIPT_DIR/hook.sh" U "$id" "$_hist_exit" 0
        fi
    elif [[ "$idx" =~ ^[0-9]+$ ]]; then
        _hist_last_idx=$idx
        _hist_initialized=1
    fi
    _hist_armed=1
}

# Session token: one per interactive shell, minted at source time (rc files
# re-run on `exec`, so the new shell gets a fresh token — never inherit).
# Subshells inherit the env var but are excluded by the recording guards
# (the DEBUG trap doesn't recurse in subshells). Carried on every W;
# session scope in the picker matches on it.
_hist_sess=$(cat /proc/sys/kernel/random/uuid 2> /dev/null) || _hist_sess=$(od -An -N16 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')

# Run the recorder on every primary prompt via bash's PROMPT_COMMAND (array
# form in bash 5.1+, scalar before); kavkash's hook goes FIRST so $? is
# still the last command's exit status when it runs.
if [[ $(declare -p PROMPT_COMMAND 2> /dev/null) == declare\ -*a* ]]; then
    PROMPT_COMMAND=(kav_precmd_record "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="kav_precmd_record${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# Preempt any existing DEBUG trap (kavkash takes it over, like
# bash-preexec does); the guards above keep it inert outside commands.
trap kav_preexec_record DEBUG

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
    bind -x '"\e[17~": _hist_scope_all'   # F6
    bind -x '"\e[18~": _hist_scope_dir'   # F7
    bind -x '"\e[19~": _hist_scope_sess'  # F8
else
    printf 'kavkash: fzf >= 0.54 required (found %s) — picker disabled; Up/Ctrl-R keep shell defaults\n' \
        "${_kav_fzf_ver:-not installed}" >&2
fi
unset _kav_fzf_ver
