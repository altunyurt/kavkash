#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Protocol (netstrings, one field per netstring):
#   Write:  W, cmd, cwd, exit_code, duration
#   Query:  Q, action [arg] [count]
db_file="$1"

# Read all stdin, parse netstrings via awk
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Netstring parser: decodes "length:payload," streams into one field per line.
# Max payload size: 1MB (prevents OOM from malicious clients).
FIELDS=$(printf '%s' "$INPUT" | LC_ALL=C awk '
BEGIN { RS = "\0" }  # treat entire input as one record
{
    data = $0; pos = 1; len = length(data)
    while (pos <= len) {
        # find colon separating length from payload
        colon = index(substr(data, pos), ":")
        if (colon == 0) break                     # no colon = malformed
        colon += pos - 1                          # convert to absolute position

        # extract and validate length prefix (digits, no leading zeros, max 1MB)
        lenstr = substr(data, pos, colon - pos)
        if (lenstr !~ /^(0|[1-9][0-9]*)$/) break
        if (lenstr + 0 > 1048576) break            # max 1MB payload

        # read exactly N bytes of payload after the colon
        payload_len = lenstr + 0
        value = substr(data, colon + 1, payload_len)
        if (length(value) != payload_len) break   # truncated payload

        # verify trailing comma delimiter
        term = colon + 1 + payload_len
        if (substr(data, term, 1) != ",") break  # missing comma

        print value                               # emit one field per line
        pos = term + 1                            # advance past this netstring
    }
}')
[ -z "$FIELDS" ] && exit 0

# Convert newline-separated fields to shell positional parameters.
# Naive "while read; do set -- \"$@\" \"$_field\"; done" is O(n²) — each set rebuilds the array.
# This approach: quote each line, join with spaces, eval once → O(n).
# Example: "W\nls -la\n/home" → set -- "W" "ls -la" "/home"
# Safe even with spaces in values because we add the quotes ourselves.
eval "set -- $(printf '%s\n' "$FIELDS" | sed 's/^/"/;s/$/"/' | paste -sd' ' -)"

TYPE="$1"; shift

case "$TYPE" in
    W)
        # Write: W cmd cwd exit_code duration
        cmd="$1"; cwd="$2"; exit_code="$3"; duration="$4"
        safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        now=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
        sqlite3 "$db_file" "INSERT INTO history (command, cwd, exit_code, duration_ms, timestamp) VALUES ('$safe_cmd', '$safe_cwd', ${exit_code:-0}, ${duration:-0}, $now);"
        ;;
    Q)
        # Query: Q action [arg] [count]
        action="$1"; arg="$2"; count="$3"
        # Validate numeric inputs (prevents SQL injection in LIMIT/OFFSET)
        case "$arg" in ''|*[!0-9]*) arg=0 ;; esac
        case "$count" in ''|*[!0-9]*) count=1 ;; esac
        case "$action" in
            up)
                sqlite3 "$db_file" "SELECT command FROM history ORDER BY timestamp DESC LIMIT $count OFFSET $arg;"
                ;;
            search)
                # Cap at 10000 results to avoid OOM on large histories
                sqlite3 "$db_file" "SELECT command FROM history ORDER BY timestamp DESC LIMIT 10000;"
                ;;
        esac
        ;;
esac
