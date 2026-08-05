#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Source includes.sh relative to THIS script (socat EXEC may have any CWD).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

#
# Wire protocol: concatenated netstrings ("len:payload,").
#   W cmd cwd id            write (preexec; id is a UUIDv7 = row timestamp)
#   U id exit_code dur_ms   update (precmd)
#   Q search query count    query -> NUL-separated rows
# Response rows: newlines display-escaped as `\n`, backslashes doubled;
# 0x1E/0x1F (sqlite3 -ascii hazards) and \r stripped. NUL framing is safe —
# command text can never contain NUL.
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
        # Write: W cmd cwd id — preexec hook. The UUIDv7 id IS the row's
        # timestamp (lexicographic id order == chronological). Exit and
        # duration are unknown until the precmd hook sends a U for id.
        cmd="$1"
        cwd="$2"
        id="$3"
        [ -n "$id" ] || exit 0

        safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        safe_id=$(printf '%s' "$id" | sed "s/'/''/g")
        # Plain INSERT: a fresh UUIDv7 cannot collide. A shell that dies
        # mid-command leaves exit 0 / duration 0; ids are never reused.
        sqlite3 "$db_file" "INSERT INTO history (id, command, cwd, exit_code, duration_ms) VALUES ('$safe_id', '$safe_cmd', '$safe_cwd', 0, 0);"
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
            changed=$(sqlite3 "$db_file" "UPDATE history SET exit_code=$exit_code, duration_ms=$duration WHERE id='$safe_id'; SELECT changes();" 2> /dev/null)
            case "$changed" in *[1-9]*) break ;; esac
            n=$((n + 1))
            sleep 0.01 2> /dev/null || break
        done
        ;;
    Q)
        # Query: up to `count` commands whose text contains every
        # whitespace-separated term as a subsequence. Each term becomes a
        # LIKE pattern with % between its characters (SQL is a superset of
        # fzf's matcher), escaping wildcards and quotes. Empty query = the
        # newest `count`. 0x1E/0x1F and \r stripped; newlines escaped as
        # `\n` (backslashes doubled) for single-line display; the response
        # is NUL-framed, clients decode on accept.
        action="$1"
        query="$2"
        count="$3"
        case "$count" in '' | *[!0-9]*) count=10000 ;; esac
        case "$action" in
            search)
                where=$(printf '%s' "$query" | LC_ALL=C awk -v q="'" '
                    {
                        n = 0
                        for (i = 1; i <= NF; i++) {
                            term = $i
                            pattern = "%"
                            j = 1
                            while (j <= length(term)) {
                                c = substr(term, j, 1)
                                # UTF-8 char width: keep multi-byte sequences
                                # intact so the % only lands between characters
                                # (splitting a multi-byte char would make the
                                # pattern unmatchable in SQLite LIKE).
                                w = 1
                                if (c >= sprintf("%c", 194) && c <= sprintf("%c", 223)) w = 2
                                else if (c >= sprintf("%c", 224) && c <= sprintf("%c", 239)) w = 3
                                else if (c >= sprintf("%c", 240) && c <= sprintf("%c", 244)) w = 4
                                ch = substr(term, j, w)
                                if (w == 1) {
                                    if (c == "%" || c == "_" || c == "\\") ch = "\\" ch
                                    else if (c == q) ch = q q
                                }
                                pattern = pattern ch "%"
                                j += w
                            }
                            clauses[++n] = "command LIKE " q pattern q " ESCAPE " q "\\" q
                        }
                    }
                    END {
                        if (n == 0) print ""
                        else {
                            printf "WHERE "
                            for (i = 1; i <= n; i++) {
                                if (i > 1) printf " AND "
                                printf "%s", clauses[i]
                            }
                            print ""
                        }
                    }')
                sql="SELECT REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(command, char(30), ''), char(31), ''), char(13), ''), char(92), char(92)||char(92)), char(10), char(92)||char(110)) FROM history $where ORDER BY id DESC LIMIT $count;"
                ;;
            *)
                exit 0
                ;;
        esac

        # sqlite3 -ascii (0x1E rows / 0x1F cols); the SELECT already stripped
        # those hazards and escaped newlines/backslashes, so no embedded
        # separator can tear a row. Rows are rejoined with 0x1E via ORS and
        # one tr converts to NUL (mawk printf eats a literal \0 in formats).
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
