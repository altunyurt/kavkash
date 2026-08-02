# kavkash bash integration — source from .bashrc.
# Requires bash-preexec.

if [[ -z "${bash_preexec_imported:-}" ]]; then
    printf "Bash-preexec is NOT loaded. If you don't have bash-preexec installed yet, visit"
    printf "\n    https://github.com/rcaloras/bash-preexec\n"
    printf "for installation instructions"
    exit 1
fi

# Shared paths/batch size from includes.sh (same dir as this file).
_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$_SCRIPT_DIR/includes.sh"

# _write_ns - netstring: "length:payload,". Byte count via wc -c
# (${#var} counts chars, not bytes — wrong under UTF-8).
_write_ns() {
    printf '%s' "$1" | {
        len=$(LC_ALL=C wc -c | tr -d ' ')
        printf '%s:%s,' "$len" "$1"
    }
}

# _read_b64 - decode server's response: one base64 row per line (EOF-terminated).
# Base64 framing survives embedded newlines in multi-line commands.
_read_b64() {
    local b64line
    while IFS= read -r b64line || [[ -n "$b64line" ]]; do
        printf '%s' "$b64line" | base64 -d 2> /dev/null
        printf '\n'
    done
}

# _hist_query - send a query to the server and return raw response
# Usage: _hist_query action [arg] [count]
# Protocol: "Q,action,arg[,count]" as concatenated netstrings
# Falls back from socat to nc if socat is unavailable
_hist_query() {
    local mode="$1"
    local arg="${2:-}"
    local count="${3:-}"

    local ns_action=$(_write_ns "$mode")
    local ns_arg=$(_write_ns "$arg")
    local payload="1:Q,${ns_action}${ns_arg}"

    if [[ -n "$count" ]]; then
        local ns_count=$(_write_ns "$count")
        payload="${payload}${ns_count}"
    fi

    if command -v socat > /dev/null 2>&1; then
        printf '%s' "$payload" | socat - UNIX-CONNECT:"$KAV_SOCK_FILE" 2> /dev/null
    elif command -v nc > /dev/null 2>&1; then
        printf '%s' "$payload" | nc -U "$KAV_SOCK_FILE" 2> /dev/null
    fi
}

# _hist_fetch - fetch batch at offset and APPEND to __hist_resultset
# (older batches pile up so navigation can keep going back).
_hist_fetch() {
    local offset="$1"
    local count="$2"
    local result
    result=$(_hist_query "up" "$offset" "$count" | _read_b64)
    if [[ -n "$result" ]]; then
        # `|| [[ -n "$line" ]]` catches a final entry without trailing newline.
        while IFS= read -r line || [[ -n "$line" ]]; do
            __hist_resultset+=("$line")
        done <<< "$result"
    fi
}

# Prefetch config — start fetching the next batch once this many entries remain
_HIST_PREFETCH_THRESHOLD=20

# _hist_prefetch_start - background-fetch the next batch via process
# substitution; skip if one is already in flight.
_hist_prefetch_start() {
    local offset="$1"
    # don't stack a second prefetch on top of one already in flight
    [[ -n "${__hist_prefetch_pid:-}" ]] && return

    exec {__hist_prefetch_fd}< <(_hist_query "up" "$offset" "$KAV_HIST_BATCH" | _read_b64)
    __hist_prefetch_pid=$!
    __hist_prefetch_offset="$offset"
}

# _hist_prefetch_collect - drain a prefetch into __hist_resultset. Blocks
# only if the background fetch is still running.
_hist_prefetch_collect() {
    [[ -z "${__hist_prefetch_fd:-}" ]] && return 1
    local line
    while IFS= read -r -u "$__hist_prefetch_fd" line || [[ -n "$line" ]]; do
        __hist_resultset+=("$line")
    done
    exec {__hist_prefetch_fd}<&-
    unset __hist_prefetch_fd __hist_prefetch_pid __hist_prefetch_offset
}

# _hist_prefetch_cancel - abandon an in-flight prefetch (from reset/cancel)
_hist_prefetch_cancel() {
    if [[ -n "${__hist_prefetch_pid:-}" ]]; then
        kill "$__hist_prefetch_pid" 2> /dev/null
    fi
    if [[ -n "${__hist_prefetch_fd:-}" ]]; then
        exec {__hist_prefetch_fd}<&-
    fi
    unset __hist_prefetch_fd __hist_prefetch_pid __hist_prefetch_offset
}

# _hist_search - Ctrl+R: open fzf with all commands for fuzzy search
# Queries server for all commands (capped at 10k), pipes through fzf,
# replaces the current line with the selected command
_hist_search() {
    local selected
    selected=$(_hist_query "search" "" | _read_b64 | fzf --height 15 --no-sort --query "$READLINE_LINE")

    if [[ -n "$selected" ]]; then
        READLINE_LINE="$selected"
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# _hist_stepper - handle Up/Down arrow history navigation
# State (all global, prefixed with __ to avoid clashes):
#   __hist_resultset[]  - array of commands, newest first (index 0 = most recent)
#   __hist_rsi          - current position in resultset (index to read next)
#   __hist_offset       - total items consumed from server (for next batch offset)
#
# Up:   if at end of resultset, fetch next batch (older commands).
#       Display resultset[__hist_rsi], advance both rsi and offset.
# Down: step back through resultset. If at start, clear line and reset.
_hist_stepper() {
    local direction="$1"
    # Hide cursor while the line is swapped: readline's full-line redraw
    # makes a visible cursor flicker mid-swap. RETURN trap restores it on
    # every exit path (incl. the early `return` when nothing was fetched),
    # and bash only fires it when THIS function returns — not nested calls.
    printf '\e[?25l'
    trap 'printf "\e[?25h"' RETURN

    # Initialize state on first invocation
    if [[ -z "${__hist_resultset+x}" ]]; then
        __hist_resultset=()
        __hist_rsi=0
        __hist_offset=0
    fi

    local rsi_len=${#__hist_resultset[@]}
    if [[ "$direction" == "up" ]]; then
        # Fetch more if we've consumed everything in the current batch
        if ((__hist_rsi >= rsi_len)); then
            local prev_len=$rsi_len
            if [[ -n "${__hist_prefetch_pid:-}" && "${__hist_prefetch_offset:-}" == "$__hist_offset" ]]; then
                _hist_prefetch_collect # usually instant — already fetched in background
            else
                _hist_fetch "$__hist_offset" "$KAV_HIST_BATCH" # fallback: cold start / prefetch missed
            fi
            rsi_len=${#__hist_resultset[@]}
            if ((rsi_len == prev_len)); then
                return
            fi
        fi

        READLINE_LINE="${__hist_resultset[$__hist_rsi]}"
        READLINE_POINT=${#READLINE_LINE}
        __hist_rsi=$((__hist_rsi + 1))
        __hist_offset=$((__hist_offset + 1))

        # stay ahead: once close to the end of what's loaded, start fetching the next batch
        if ((rsi_len - __hist_rsi <= _HIST_PREFETCH_THRESHOLD)) && [[ -z "${__hist_prefetch_pid:-}" ]]; then
            _hist_prefetch_start "$__hist_offset"
        fi

    elif [[ "$direction" == "down" ]]; then
        if ((rsi_len > 0 && __hist_rsi > 0)); then
            # Step back within the resultset
            __hist_rsi=$((__hist_rsi - 1))
            __hist_offset=$((__hist_offset - 1))
            if ((__hist_rsi > 0)); then
                # Step back: show the entry before the new rsi (last up
                # displayed resultset[old_rsi] then incremented rsi).
                READLINE_LINE="${__hist_resultset[$((__hist_rsi - 1))]}"
                READLINE_POINT=${#READLINE_LINE}
            else
                # At the first history entry — clear line and reset
                READLINE_LINE=""
                READLINE_POINT=0
                unset __hist_resultset __hist_rsi __hist_offset
            fi
        else
            # Past the start — clear line and reset state
            READLINE_LINE=""
            READLINE_POINT=0
            unset __hist_resultset __hist_rsi __hist_offset
        fi
    fi
}

# bind -x doesn't pass arguments directly, so wrap with direction argument
# Up wrapper times press->redraw: readline repaints right after this returns,
# so elapsed ≈ redraw latency. Prints to stderr (keeps stdout clean for IPC).
_hist_stepper_up() {
    local _t0=$EPOCHREALTIME
    _hist_stepper "up"
    local _t1=$EPOCHREALTIME

    if [[ $KAV_DEBUG -eq 1 ]]; then
        printf 'kavkash debug: up->redraw %.1f ms\n' "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN{printf "%.1f", (b-a)*1000}')" >&2
    fi
}
_hist_stepper_down() { _hist_stepper "down"; }

# _hist_reset - clear navigation state. Hooked to bash-preexec's precmd;
# Enter itself is left unbound so it executes the command normally.
_hist_reset() {
    _hist_prefetch_cancel
    unset __hist_resultset __hist_rsi __hist_offset
}

# _hist_cancel - Ctrl+C: clear state, cancel the current line
_hist_cancel() {
    _hist_prefetch_cancel
    unset __hist_resultset __hist_rsi __hist_offset
}

# _hist_bind_keys - register all key bindings. bind -x runs the function
# directly (not just inserts text). Enter is NOT bound — normal readline
# Enter executes the command; state is cleared by precmd_hist_reset.
_hist_bind_keys() {
    bind -x '"\C-r": _hist_search'
    bind -x '"\e[A": _hist_stepper_up'
    bind -x '"\e[B": _hist_stepper_down'

    bind -x '"\C-c": _hist_cancel'
}

_hist_bind_keys

_hist_corr=""
_hist_corr_n=0

preexec_hook() {
    _hist_corr_n=$((_hist_corr_n + 1))
    _hist_corr="${BASHPID}-${_hist_corr_n}"
    "$_SCRIPT_DIR/hook.sh" W "$1" "$PWD" "$_hist_corr"
}
preexec_functions+=(preexec_hook)

# precmd: clear navigation state AND report the finished line's exit code.
# bash-preexec restores the real $? before invoking each precmd function
# (__bp_set_ret_value in bash-preexec.sh), so capturing it first is safe.
precmd_hist_reset() {
    local _hist_exit=$?
    _hist_reset 2> /dev/null
    if [[ -n $_hist_corr ]]; then
        "$_SCRIPT_DIR/hook.sh" U "$_hist_corr" "$_hist_exit"
        _hist_corr=""
    fi
}
precmd_functions+=(precmd_hist_reset)

# Preload the first batch so the first Up press doesn't block on IPC
_hist_prefetch_start 0
