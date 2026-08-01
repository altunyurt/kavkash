# Configuration: socket path and batch size for history navigation
# Must match includes.sh: ${XDG_RUNTIME_DIR}/kavkash/history.sock. fish cannot
# source includes.sh (POSIX sh syntax), so these stay duplicated — keep in sync.
if set -q XDG_RUNTIME_DIR
    set -g _HIST_SOCK "$XDG_RUNTIME_DIR/kavkash/history.sock"
else
    set -g _HIST_SOCK "/tmp/kavkash/history.sock"
end
set -g _HIST_BATCH 100
# Directory containing this file (project root); hook.sh lives beside it.
# Resolved to a REAL path: fish refuses to exec command paths containing "..".
set -g _HIST_SCRIPT_DIR (dirname (status filename))
set -g _HIST_HOOK (realpath "$_HIST_SCRIPT_DIR/hook.sh")

# _write_ns - encode a string as a netstring: "length:payload,"
# Uses wc -c for byte count (works for any byte sequence, not just text)
function _write_ns
    set -l len (printf '%s' "$argv[1]" | LC_ALL=C wc -c | tr -d ' ')
    printf '%s:%s,' "$len" "$argv[1]"
end

# _read_b64 - decode server's response: one base64 row per line (EOF-terminated).
# Base64 framing survives embedded newlines in multi-line commands.
function _read_b64
    while begin
            read b64line
            or test -n "$b64line"
        end
        printf '%s' "$b64line" | base64 -d 2>/dev/null
        echo
    end
end

# _hist_query - send a query to the server and return raw response
# Usage: _hist_query action [arg] [count]
# Protocol: "Q,action,arg[,count]" as concatenated netstrings
function _hist_query
    set -l mode $argv[1]
    set -l arg $argv[2]
    set -l count $argv[3]

    set -l ns_action (_write_ns "$mode")
    set -l ns_arg (_write_ns "$arg")
    set -l payload (printf '1:Q,%s%s' "$ns_action" "$ns_arg")

    if test -n "$count"
        set -l ns_count (_write_ns "$count")
        set payload "$payload$ns_count"
    end

    if command -vq socat
        printf '%s' "$payload" | socat - UNIX-CONNECT:"$_HIST_SOCK" 2>/dev/null
    else if command -vq nc
        printf '%s' "$payload" | nc -U "$_HIST_SOCK" 2>/dev/null
    end
end

# _hist_fetch - fetch batch at offset and APPEND to __hist_resultset
# (older batches pile up so navigation can keep going back).
function _hist_fetch
    set -l offset $argv[1]
    set -l count $argv[2]
    set -l result (_hist_query "up" "$offset" "$count" | _read_b64)
    if test -n "$result"
        set -a __hist_resultset $result
    end
end

# _hist_search - Ctrl+R: open fzf with all commands for fuzzy search
# Queries server for all commands (capped at 10k), pipes through fzf,
# replaces the current line with the selected command
function _hist_search
    set -l selected (_hist_query "search" "" | _read_b64 | fzf --height 15 --no-sort --query (commandline -b))
    if test -n "$selected"
        commandline -r "$selected"
    end
    commandline -f repaint
end

# _hist_stepper - handle Up/Down arrow history navigation
# State (all global, prefixed with __ to avoid clashes):
#   __hist_resultset  - array of commands, newest first (index 1 = most recent)
#   __hist_rsi        - current position in resultset (index to read next)
#   __hist_offset     - total items consumed from server (for next batch offset)
#
# Up:   if at end of resultset, fetch next batch (older commands).
#       Display resultset[__hist_rsi], advance both rsi and offset.
# Down: step back through resultset. If at start, clear line and reset.
# Note: fish arrays are 1-indexed.
function _hist_stepper
    if not set -q __hist_resultset
        set -g __hist_resultset
        set -g __hist_rsi 1
        set -g __hist_offset 0
    end

    set -l rsi_len (count $__hist_resultset)

    switch "$argv[1]"
        case up
            # Fetch more if we've consumed everything in the current batch
            if test $__hist_rsi -gt $rsi_len
                set -l prev_len $rsi_len
                _hist_fetch $__hist_offset $_HIST_BATCH
                set rsi_len (count $__hist_resultset)
                # If nothing new fetched, we've hit the end of history
                if test $rsi_len -eq $prev_len
                    return
                end
            end
            commandline -r "$__hist_resultset[$__hist_rsi]"
            set -g __hist_rsi (math $__hist_rsi + 1)
            set -g __hist_offset (math $__hist_offset + 1)
            commandline -f repaint

        case down
            if test $rsi_len -gt 0; and test $__hist_rsi -gt 1
                # Step back within the resultset
                set -g __hist_rsi (math $__hist_rsi - 1)
                set -g __hist_offset (math $__hist_offset - 1)
                if test $__hist_rsi -gt 1
                    # Show index rsi-1 (one step before the new rsi). fish is 1-indexed.
                    # (fish can't expand a command-substitution index inside quotes)
                    set -l idx (math $__hist_rsi - 1)
                    commandline -r "$__hist_resultset[$idx]"
                else
                    # At the first history entry — clear line and reset
                    commandline -r ""
                    set -e __hist_resultset __hist_rsi __hist_offset
                end
                commandline -f repaint
            else
                # Past the start — clear line and reset state
                commandline -r ""
                set -e __hist_resultset __hist_rsi __hist_offset
                commandline -f repaint
            end
    end
end

# _hist_stepper_up - Up arrow wrapper.
function _hist_stepper_up
    _hist_stepper up
end

# _hist_stepper_down - Down arrow wrapper.
function _hist_stepper_down
    _hist_stepper down
end

# _hist_reset - clear navigation state (called via fish_postexec below)
function _hist_reset
    set -e __hist_resultset __hist_rsi __hist_offset
end

# Record executed commands: fire-and-forget write to the daemon (like bash/zsh).
# fish_preexec fires for the whole command line once, just before it runs.
# Skip empty lines and commands spawned from command substitutions (e.g. fzf
# inside _hist_search) so we only store what the user actually typed.
function _hist_preexec --on-event fish_preexec
    status is-command-substitution; and return 0
    [ -n "$argv[1]" ]; or return 0

    "$_HIST_HOOK" "$argv[1]" "$PWD" "" "" &
end

# _hist_cancel - Ctrl+C: clear state, cancel the current line
function _hist_cancel
    set -e __hist_resultset __hist_rsi __hist_offset
    commandline -f cancel-commandline
end

# fish_user_key_bindings - register all key bindings.
# Enter is NOT bound — fish's normal Enter executes the command.
function fish_user_key_bindings
    bind --user --erase up 2>/dev/null
    bind --user --erase down 2>/dev/null
    bind --user --erase \cr 2>/dev/null

    # Bind by keyname AND by raw escape sequence: fish resolves incoming
    # bytes against raw-sequence bindings first, so a keyname-only binding
    # can lose to the preset up-line/down-line (fish's own history).
    bind --user up _hist_stepper_up
    bind --user down _hist_stepper_down
    bind --user -M insert up _hist_stepper_up
    bind --user -M insert down _hist_stepper_down
    bind --user \e\[A _hist_stepper_up
    bind --user \e\[B _hist_stepper_down
    bind --user -M insert \e\[A _hist_stepper_up
    bind --user -M insert \e\[B _hist_stepper_down
    bind --user \eOA _hist_stepper_up
    bind --user \eOB _hist_stepper_down
    bind --user -M insert \eOA _hist_stepper_up
    bind --user -M insert \eOB _hist_stepper_down
    bind --user \cr _hist_search
    bind --user -M insert \cr _hist_search
    bind --user \cc _hist_cancel
end

# Apply bindings now: fish only auto-calls fish_user_key_bindings at startup,
# so a mid-session `source functions.fish` would otherwise never bind.
fish_user_key_bindings

# Clear navigation state after each command completes
# fish_postexec fires after a command line finishes
function _hist_postexec --on-event fish_postexec
    _hist_reset 2>/dev/null
end

# Preload the first batch so the first Up press doesn't block on IPC.
# Pre-init state explicitly (stepper skips lazy init when the resultset
# exists) and fetch synchronously to avoid a race on the first keypress.
set -g __hist_resultset
set -g __hist_rsi 1
set -g __hist_offset 0
_hist_fetch 0 $_HIST_BATCH
