# Configuration: socket path and batch size for history navigation
# The socket lives under XDG_RUNTIME_DIR (matches includes.sh on the daemon
# side). The shell does NOT source config — no kavkash config variables
# enter the interactive session.
_SCRIPT_DIR=${0:A:h:h}   # kavkash root, where hook.sh lives
_HIST_SOCK="${XDG_RUNTIME_DIR:-/tmp}/kavkash/history.sock"
_HIST_BATCH=100

# _write_ns - encode a string as a netstring: "length:payload,"
# Byte count via wc -c (locale-independent; ${#var} counts chars, not bytes)
_write_ns() {
    local len
    len=$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')
    printf '%s:%s,' "$len" "$1"
}

# _read_b64 - decode the server's query-response stream into one field per line.
# Wire format (see processor.sh): one base64-encoded row per line, EOF-terminated.
# Base64 is used instead of raw text because history entries (e.g. multi-line
# commands) may contain embedded newlines, which would otherwise corrupt the
# line-based framing.
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
    local mode="$1" arg="${2:-}" count="${3:-}" ns_action ns_arg ns_count payload
    ns_action=$(_write_ns "$mode")
    ns_arg=$(_write_ns "$arg")
    payload="1:Q,${ns_action}${ns_arg}"
    if [[ -n "$count" ]]; then
        ns_count=$(_write_ns "$count")
        payload="${payload}${ns_count}"
    fi
    if command -v socat > /dev/null 2>&1; then
        printf '%s' "$payload" | socat - UNIX-CONNECT:"$_HIST_SOCK" 2> /dev/null
    elif command -v nc > /dev/null 2>&1; then
        printf '%s' "$payload" | nc -U "$_HIST_SOCK" 2> /dev/null
    fi
}

# _hist_fetch - fetch a batch of commands and APPEND to __hist_resultset
# Args: offset count
_hist_fetch() {
    local offset="$1" count="$2" result line
    result=$(_hist_query "up" "$offset" "$count" | _read_b64)
    if [[ -n "$result" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            __hist_resultset+=("$line")
        done <<< "$result"
    fi
}

# Prefetch config — start fetching the next batch once this many entries remain
_HIST_PREFETCH_THRESHOLD=20

# _hist_prefetch_start - kick off the next batch fetch in the background.
# Uses `exec {fd}< <(...)` (backgrounded process substitution): the pipeline
# starts immediately, we get a live fd to drain whenever ready. No pid tracking
# — zsh's $! is 0 for process substitution, and the fd alone is enough to
# guard against stacking and to cancel (closing it SIGPIPEs the writer).
_hist_prefetch_start() {
    local offset="$1"
    [[ -n "${__hist_prefetch_fd:-}" ]] && return

    exec {__hist_prefetch_fd}< <(_hist_query "up" "$offset" "$_HIST_BATCH" | _read_b64)
    __hist_prefetch_offset="$offset"
}

# _hist_prefetch_collect - drain a completed (or still-running) prefetch into
# __hist_resultset. Blocks only if the background fetch hasn't finished yet —
# same worst case as a synchronous fetch, but usually it's already done.
_hist_prefetch_collect() {
    [[ -z "${__hist_prefetch_fd:-}" ]] && return 1
    local line
    while IFS= read -r -u "$__hist_prefetch_fd" line || [[ -n "$line" ]]; do
        __hist_resultset+=("$line")
    done
    exec {__hist_prefetch_fd}<&-
    unset __hist_prefetch_fd __hist_prefetch_offset
}

# _hist_prefetch_cancel - abandon any in-flight prefetch (call from _hist_reset/_hist_cancel)
_hist_prefetch_cancel() {
    if [[ -n "${__hist_prefetch_fd:-}" ]]; then
        exec {__hist_prefetch_fd}<&-
    fi
    unset __hist_prefetch_fd __hist_prefetch_offset
}

# _hist_search - Ctrl+R: open fzf with all commands for fuzzy search
# Queries server for all commands (capped at 10k), pipes through fzf,
# replaces the current line with the selected command
_hist_search() {
    local selected
    selected=$(_hist_query "search" "" | _read_b64 | fzf --height 15 --no-sort --query "$BUFFER")
    if [[ -n "$selected" ]]; then
        BUFFER="$selected"
        CURSOR=${#BUFFER}
    fi
    zle reset-prompt
    return 0
}

# _hist_stepper - handle Up/Down arrow history navigation
# State (all global, prefixed with __ to avoid clashes):
#   __hist_resultset  - array of commands, newest first (index 1 = most recent)
#   __hist_rsi        - index to read next on Up
#   __hist_offset     - total items consumed from server (next batch offset)
#
# Up:   if at end of resultset, fetch next batch (older commands).
#       Display resultset[__hist_rsi], advance both rsi and offset.
# Down: step back through resultset. If at start, clear line and reset.
_hist_stepper() {
    local direction="$1"
    if [[ -z "${__hist_resultset+x}" ]]; then
        __hist_resultset=()
        __hist_rsi=1
        __hist_offset=0
    fi

    local rsi_len=${#__hist_resultset[@]}
    if [[ "$direction" == "up" ]]; then
        # Fetch more if we've consumed everything in the current batch
        if ((__hist_rsi > rsi_len)); then
            local prev_len=$rsi_len
            if [[ -n "${__hist_prefetch_fd:-}" && "${__hist_prefetch_offset:-}" == "$__hist_offset" ]]; then
                _hist_prefetch_collect # usually instant — already fetched in background
            else
                _hist_fetch "$__hist_offset" "$_HIST_BATCH" # fallback: cold start / prefetch missed
            fi
            rsi_len=${#__hist_resultset[@]}
            if ((rsi_len == prev_len)); then
                return 0
            fi
        fi

        BUFFER="${__hist_resultset[$__hist_rsi]}"
        CURSOR=${#BUFFER}
        __hist_rsi=$((__hist_rsi + 1))
        __hist_offset=$((__hist_offset + 1))

        # stay ahead: once close to the end of what's loaded, start fetching the next batch.
        # Prefetch at rsi_len (= the offset where the current batch ends) so the collect
        # check below (prefetch_offset == __hist_offset) matches at the boundary.
        if ((rsi_len - __hist_rsi <= _HIST_PREFETCH_THRESHOLD)) && [[ -z "${__hist_prefetch_fd:-}" ]]; then
            _hist_prefetch_start "$rsi_len"
        fi

    elif [[ "$direction" == "down" ]]; then
        if ((rsi_len > 0 && __hist_rsi > 1)); then
            # Step back within the resultset
            __hist_rsi=$((__hist_rsi - 1))
            __hist_offset=$((__hist_offset - 1))
            if ((__hist_rsi > 1)); then
                # Show index rsi-1 (one step before the new rsi), since the last up
                # displayed resultset[old_rsi] then incremented rsi to old_rsi+1.
                BUFFER="${__hist_resultset[$((__hist_rsi - 1))]}"
                CURSOR=${#BUFFER}
            else
                # At the first history entry — clear line and reset
                BUFFER=""
                CURSOR=0
                unset __hist_resultset __hist_rsi __hist_offset
            fi
        else
            # Past the start — clear line and reset state
            BUFFER=""
            CURSOR=0
            unset __hist_resultset __hist_rsi __hist_offset
        fi
    fi
    return 0
}

# zle widgets can't take arguments, so wrap with direction
_hist_stepper_up() { _hist_stepper "up" }
_hist_stepper_down() { _hist_stepper "down" }

# _hist_reset - clear navigation state (called by precmd hook, NOT bound to Enter)
_hist_reset() {
    _hist_prefetch_cancel
    unset __hist_resultset __hist_rsi __hist_offset
}

# _hist_cancel - Ctrl+C: clear state, cancel the current line
_hist_cancel() {
    _hist_prefetch_cancel
    unset __hist_resultset __hist_rsi __hist_offset
    BUFFER=""
    CURSOR=0
    zle reset-prompt
    return 0
}

# Register all zle widgets and key bindings
# ^[[A = Up arrow, ^[[B = Down arrow, ^R = Ctrl+R, ^C = Ctrl+C
# Enter is NOT bound — normal readline Enter executes the command.
zle -N kavkash-search _hist_search
zle -N kavkash-stepper-up _hist_stepper_up
zle -N kavkash-stepper-down _hist_stepper_down
zle -N kavkash-cancel _hist_cancel

bindkey '^R' kavkash-search
bindkey '^[[A' kavkash-stepper-up
bindkey '^[[B' kavkash-stepper-down
bindkey '^C' kavkash-cancel

# Record executed commands and clear navigation state after each one
autoload -Uz add-zsh-hook

_hist_preexec() {
    "$_SCRIPT_DIR/hook.sh" "${2:-$1}" "$PWD" "" "" &
}

_hist_precmd() {
    _hist_reset 2> /dev/null
}

add-zsh-hook preexec _hist_preexec
add-zsh-hook precmd _hist_precmd

# Preload the first batch so the first Up press doesn't block on IPC
_hist_prefetch_start 0
