#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Protocol (netstrings, one field per netstring):
#   Write:  W, cmd, cwd, exit_code, duration
#   Query:  Q, action, arg
db_file="$1"

# Read all stdin, parse netstrings via awk
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

FIELDS=$(printf '%s' "$INPUT" | LC_ALL=C awk '
BEGIN { RS = "\0" }
{
    data = $0; pos = 1; len = length(data); n = 0
    while (pos <= len) {
        colon = index(substr(data, pos), ":")
        if (colon == 0) break
        colon += pos - 1
        lenstr = substr(data, pos, colon - pos)
        if (lenstr !~ /^(0|[1-9][0-9]*)$/) break
        payload_len = lenstr + 0
        value = substr(data, colon + 1, payload_len)
        if (length(value) != payload_len) break
        term = colon + 1 + payload_len
        if (substr(data, term, 1) != ",") break
        print value
        pos = term + 1
        n++
    }
}')
[ -z "$FIELDS" ] && exit 0

# Read fields line by line (avoids word-splitting on spaces)
set --
while IFS= read -r _field; do
    set -- "$@" "$_field"
done <<EOF
$FIELDS
EOF
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
        # Query: Q action arg
        action="$1"; arg="$2"
        case "$action" in
            up)
                result=$(sqlite3 "$db_file" "SELECT command FROM history ORDER BY timestamp DESC LIMIT 1 OFFSET $arg;")
                [ -n "$result" ] && printf '%s\n' "$result"
                ;;
            search)
                sqlite3 "$db_file" "SELECT command FROM history ORDER BY timestamp DESC;"
                ;;
        esac
        ;;
esac
