#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Source includes.sh relative to THIS script (socat EXEC may have any CWD).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

#
# Wire protocol:
#   Client -> Server: concatenated netstrings ("len:payload,")
#       Write:  W, cmd, cwd, corr        (preexec; exit/duration unknown yet)
#       Update: U, corr, exit_code       (precmd; duration = now - row.timestamp;
#                                        corr cleared so PIDs can be reused)
#       Query:  Q, action [arg] [count]
#   Server -> Client (Q only): one base64-encoded row per line (EOF-terminated).
#       Base64 is used instead of raw text because history entries (e.g.
#       multi-line commands) may contain embedded newlines, which would
#       otherwise corrupt line-based framing.
db_file="${KAV_DB_FILE:-$1}" # computed by includes.sh (sourced above); $1 fallback for manual invocation

# Bound total bytes read to defend against unbounded-buffering DoS from a
# client that never sends a valid netstring (no colon => awk parser would
# otherwise still have consumed all of `cat`'s output before rejecting it).
INPUT=$(head -c 2097152)
[ -z "$INPUT" ] && exit 0

# Netstring parser: decodes "length:payload," into fields.
# Each field is emitted base64-encoded, one per output line. Base64 output
# is guaranteed newline-free (with -w0) and NUL-free, so it survives a
# shell command-substitution round trip intact regardless of what bytes
# (including raw newlines) the original payload contained.
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
        if (substr(data, term, 1) != ",") break    # missing comma

        # emit field as base64 on its own line (newline-safe framing)
        b64cmd = "base64 -w0"
        printf "%s", value | b64cmd
        close(b64cmd)
        print ""

        pos = term + 1                             # advance past this netstring
    }
}')
[ -z "$FIELDS" ] && exit 0

# Reconstruct positional parameters from base64-decoded fields (avoids eval/RCE).
set --
while IFS= read -r b64field || [ -n "$b64field" ]; do
    field=$(printf '%s' "$b64field" | base64 -d 2> /dev/null)
    set -- "$@" "$field"
done << EOF
$FIELDS
EOF

[ "$#" -eq 0 ] && exit 0

TYPE="$1"
shift

case "$TYPE" in
    W)
        # Write: W cmd cwd corr — preexec hook. Exit/duration are unknown
        # until the command completes; the precmd hook sends a U for corr.
        cmd="$1"
        cwd="$2"
        corr="$3"

        safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        safe_corr=$(printf '%s' "$corr" | sed "s/'/''/g")
        now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
        if [ -n "$corr" ]; then
            # OR REPLACE: a corr key is only unique while its command is
            # pending, so the only possible conflict is a stale row from a
            # shell that died mid-command AND had its PID+counter reused.
            # Recycle it instead of silently dropping the new command.
            sqlite3 "$db_file" "INSERT OR REPLACE INTO history (command, cwd, exit_code, duration_ms, timestamp, corr) VALUES ('$safe_cmd', '$safe_cwd', 0, 0, $now, '$safe_corr');"
        else
            sqlite3 "$db_file" "INSERT INTO history (command, cwd, exit_code, duration_ms, timestamp) VALUES ('$safe_cmd', '$safe_cwd', 0, 0, $now);"
        fi
        ;;
    U)
        # Update: U corr exit_code — precmd hook fires after the command
        # line finished; $? is the line's exit. Duration is computed from the
        # row's preexec timestamp (same server clock). corr is cleared in the
        # same statement (WHERE matches before SET), freeing the key for PID
        # reuse — it is only meaningful while the command is pending.
        corr="$1"
        exit_code="$2"
        [ -n "$corr" ] || exit 0
        case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
        safe_corr=$(printf '%s' "$corr" | sed "s/'/''/g")
        now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
        sqlite3 "$db_file" "UPDATE history SET exit_code=$exit_code, duration_ms=CASE WHEN $now > timestamp THEN $now - timestamp ELSE 0 END, corr=NULL WHERE corr='$safe_corr';"
        ;;
    Q)
        # Query: Q action [arg] [count]
        action="$1"
        arg="$2"
        count="$3"
        # Validate numeric inputs (prevents SQL injection in LIMIT/OFFSET)
        case "$arg" in '' | *[!0-9]*) arg=0 ;; esac
        case "$count" in '' | *[!0-9]*) count=1 ;; esac
        case "$action" in
            up)
                sql="SELECT command FROM history ORDER BY timestamp DESC LIMIT $count OFFSET $arg;"
                ;;
            search)
                # Cap at 10000 results to avoid OOM on large histories
                sql="SELECT command FROM history ORDER BY timestamp DESC LIMIT 10000;"
                ;;
            *)
                sql=""
                ;;
        esac
        [ -z "$sql" ] && exit 0

        # Use -ascii mode (0x1E row separator, 0x1F column separator)
        # instead of sqlite3's default newline-separated list output.
        # A history entry containing an embedded literal newline would
        # otherwise be mis-split into multiple bogus "rows" by any
        # newline-based consumer downstream.
        sqlite3 -ascii "$db_file" "$sql" | LC_ALL=C awk '
        BEGIN { RS = "\036" }
        {
            row = $0
            sub(/\n$/, "", row)   # strip sqlite3 trailing newline artifact, if any
            if (row == "") next   # sqlite3 -ascii trailing-separator artifact; real rows are never empty
            b64cmd = "base64 -w0"
            printf "%s", row | b64cmd
            close(b64cmd)
            print ""
        }'
        ;;
esac
