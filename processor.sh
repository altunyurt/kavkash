#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Source includes.sh relative to THIS script (socat EXEC may have any CWD).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"
#
# Wire protocol: concatenated netstrings ("len:payload,").
#   W cmd cwd id session    write (preexec; id = ns-since-epoch = row
#                           timestamp, session = per-shell token, '' = none)
#   U id exit_code dur_ms   update (precmd)
#   Q search query count cwd session
#                           query -> NUL-separated rows; cwd/session scope
#                           BEFORE the LIMIT (client-side filtering would
#                           miss old rows past the window cut). cwd matches
#                           the dir + subtree; "/" is a no-op.
# Rows carry raw command text — multi-line commands pass through intact
# (fzf >= 0.53 renders them natively); only 0x1E/0x1F (sqlite3 -ascii
# hazards) and \r are stripped. NUL framing is safe: command text can
# never contain NUL.
db_file="${KAV_DB_FILE:-$1}" # computed by includes.sh (sourced above); $1 fallback for manual invocation

# Bound input size: a client that never sends a valid netstring would
# otherwise buffer unboundedly in the awk parser.
INPUT=$(head -c 2097152)
[ -z "$INPUT" ] && exit 0

# Netstring parser: decodes "length:payload," into base64 fields, one per
# line — base64 is newline/NUL-free, so fields survive the $(...) round
# trip intact. Max payload 1MB (OOM guard).
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
        # Write: W cmd cwd id session — preexec hook. The id is ns-since-
        # epoch: the row's timestamp, so id order == chronological. Exit and
        # duration are unknown until the precmd hook sends a U for id.
        cmd="$1"
        cwd="$2"
        id="$3"
        session="$4"
        # id must be an integer (INTEGER PRIMARY KEY); drop anything else
        # (garbage on the wire).
        case "$id" in '' | *[!0-9]*) exit 0 ;; esac

        safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        safe_session=$(printf '%s' "$session" | sed "s/'/''/g")
        # Plain INSERT: two commands in the same nanosecond cannot happen
        # (each hook call itself takes µs-ms). A shell that dies mid-
        # command leaves exit 0 / duration 0; ids are never reused.
        # busy_timeout makes concurrent writers (several terminals at once)
        # wait for the lock instead of failing with SQLITE_BUSY. Empty
        # session -> NULL (pre-session rows are NULL too; session scope
        # matches non-NULL tokens only).
        sqlite3 "$db_file" "PRAGMA busy_timeout = 3000; INSERT INTO history (id, command, cwd, exit_code, duration_ms, session) VALUES ($id, '$safe_cmd', '$safe_cwd', 0, 0, NULLIF('$safe_session', ''));"
        ;;
    U)
        # Update: precmd reports $? and shell-measured duration for the id.
        # Bash fires W and U back-to-back in separate fire-and-forget
        # connections (zsh/fish run a whole command between them), so the U
        # can win the race and find no row yet — retry briefly.
        id="$1"
        exit_code="$2"
        duration="$3"
        [ -n "$id" ] || exit 0
        case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
        case "$duration" in '' | *[!0-9]*) duration=0 ;; esac
        safe_id=$(printf '%s' "$id" | sed "s/'/''/g")
        n=0
        while [ "$n" -lt 5 ]; do
            changed=$(sqlite3 "$db_file" "PRAGMA busy_timeout = 3000; UPDATE history SET exit_code=$exit_code, duration_ms=$duration WHERE id='$safe_id'; SELECT changes();" 2> /dev/null)
            case "$changed" in *[1-9]*) break ;; esac
            n=$((n + 1))
            sleep 0.01 2> /dev/null || break
        done
        ;;
    Q)
        # Query: newest `count` commands matching the scope, NUL-framed raw
        # rows. The picker always sends an empty query — fzf filters the
        # loaded window in-memory — so the query field is accepted for
        # protocol stability and ignored (the server-side subsequence
        # matcher is long gone). cwd/session scope (empty = no filter)
        # applies BEFORE the LIMIT: the picker's window is "newest N
        # matching the scope".
        action="$1"
        count="$3"
        cwd="$4"
        session="$5"
        case "$count" in '' | *[!0-9]*) count=10000 ;; esac
        case "$action" in
            search) ;;
            *) exit 0 ;;
        esac
        where=""
        if [ -n "$cwd" ] && [ "$cwd" != "/" ]; then
            sc=$(printf '%s' "$cwd" | sed "s/'/''/g")
            # the dir itself + subtree; "/" (everything) is a no-op above
            where="(cwd = '$sc' OR cwd LIKE '$sc/%')"
        fi
        if [ -n "$session" ]; then
            ss=$(printf '%s' "$session" | sed "s/'/''/g")
            where="${where:+$where AND }session = '$ss'"
        fi
        sql="SELECT REPLACE(REPLACE(REPLACE(command, char(30), ''), char(31), ''), char(13), '') FROM history${where:+ WHERE $where} ORDER BY id DESC LIMIT $count;"

        # sqlite3 -ascii (0x1E rows / 0x1F cols); the SELECT already stripped
        # those hazards, so no embedded separator can tear a row. Rows are
        # rejoined with 0x1E via ORS and one tr converts to NUL (mawk printf
        # eats a literal \0 in formats).
        # Read-only SELECT: no busy_timeout (a PRAGMA assignment would make
        # the sqlite3 CLI echo "3000" into the picker stream).
        sqlite3 -ascii "$db_file" "$sql" | LC_ALL=C awk '
        BEGIN { RS = "\036"; ORS = "\036" }
        {
            row = $0
            sub(/\n$/, "", row)   # strip sqlite3 trailing newline artifact, if any
            if (row == "") next   # sqlite3 -ascii trailing-separator artifact; real rows are never empty
            print row
        }' | tr '\036' '\000'
        ;;
esac
