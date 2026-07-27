# Configuration
set -g _HIST_SOCK "${XDG_RUNTIME_DIR:-/tmp}/history.sock"

# Netstring helpers
function _write_ns
    set -l len (printf '%s' "$argv[1]" | LC_ALL=C wc -c | tr -d ' ')
    printf '%s:%s,' "$len" "$argv[1]"
end

function _read_ns
    LC_ALL=C awk '
    BEGIN { RS = "\0" }
    {
        data = $0; pos = 1; len = length(data)
        while (pos <= len) {
            colon = index(substr(data, pos), ":")
            if (colon == 0) break
            colon += pos - 1
            lenstr = substr(data, pos, colon - pos)
            if (lenstr !~ /^(0|[1-9][0-9]*)$/) break
            n = lenstr + 0
            value = substr(data, colon + 1, n)
            if (length(value) != n) break
            term = colon + 1 + n
            if (substr(data, term, 1) != ",") break
            print value
            pos = term + 1
        }
    }'
end

# Socket Communication Helper
function _hist_query
    set -l mode $argv[1]
    set -l arg $argv[2]

    # Build netstring query: Q, action, arg
    set -l ns_action (_write_ns "$mode")
    set -l ns_arg (_write_ns "$arg")
    set -l payload (printf '1:Q,%s%s' "$ns_action" "$ns_arg")

    if command -vq socat
        printf '%s' "$payload" | socat - UNIX-CONNECT:"$_HIST_SOCK" 2>/dev/null
    else if command -vq nc
        printf '%s' "$payload" | nc -U "$_HIST_SOCK" 2>/dev/null
    end
end

# fzf Search Trigger (Ctrl+R)
function _hist_search
    set -l selected (_hist_query "search" "" | _read_ns | fzf --height 15 --no-sort --query (commandline -b))
    if test -n "$selected"
        commandline -r "$selected"
    end
    commandline -f repaint
end

# Up/Down Stepper
function _hist_stepper
    if not set -q __hist_index
        set -g __hist_index 0
        set -g __hist_saved_cmd (commandline -b)
    end

    switch "$argv[1]"
        case up
            set -l offset $__hist_index
            set -l cmd (_hist_query "up" "$offset" | _read_ns)
            if test -n "$cmd"
                set -g __hist_index (math $__hist_index + 1)
                commandline -r "$cmd"
                commandline -f repaint
            end
        case down
            if test $__hist_index -gt 1
                set -g __hist_index (math $__hist_index - 1)
                set -l offset (math $__hist_index - 1)
                set -l cmd (_hist_query "up" "$offset" | _read_ns)
                if test -n "$cmd"
                    commandline -r "$cmd"
                    commandline -f repaint
                end
            else
                commandline -r "$__hist_saved_cmd"
                set -e __hist_index
                set -e __hist_saved_cmd
                commandline -f repaint
            end
    end
end

# Reset State on Execution
function _hist_reset
    set -e __hist_index
    set -e __hist_saved_cmd
    commandline -f execute
end

# Cancel Buffer State
function _hist_cancel
    set -e __hist_index
    set -e __hist_saved_cmd
    commandline -f cancel-commandline
end

# Key Bindings Setup
function fish_user_key_bindings
    bind --user --erase up 2>/dev/null
    bind --user --erase down 2>/dev/null
    bind --user --erase \cr 2>/dev/null

    bind --user up "_hist_stepper up"
    bind --user down "_hist_stepper down"
    bind --user \cr _hist_search
    bind --user -M insert \cr _hist_search
    bind --user \r _hist_reset
    bind --user \n _hist_reset
    bind --user \cc _hist_cancel
end
