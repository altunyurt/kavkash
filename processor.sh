#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Source includes.sh relative to THIS script (socat EXEC may have any CWD).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

#
# Wire protocol:
#   Client -> Server: concatenated netstrings ("len:payload,")
#       Write:  W, cmd, cwd, id        (preexec; id is a UUIDv7 minted by
#                                       hook.sh — it doubles as the row's
#                                       timestamp; exit/duration unknown yet)
#       Update: U, id, exit_code, duration_ms
#                                     (precmd; duration measured by the shell
#                                     between preexec and precmd)
#       Query:  Q, search, query, count
#   Server -> Client (Q only): NUL-separated rows (one row per record).
#       Embedded newlines are display-escaped as `\n` (and `\` doubled)
#       so each command renders on one line in the picker; 0x1E/0x1F
#       (sqlite3 -ascii framing hazards) and \r are stripped. NUL framing
#       is unambiguous — command text can never contain NUL.
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
        # mid-command leaves its row at exit 0 / duration 0 — visible as
        # history; ids are never reused, so it can never be resurrected.
        sqlite3 "$db_file" "INSERT INTO history (id, command, cwd, exit_code, duration_ms) VALUES ('$safe_id', '$safe_cmd', '$safe_cwd', 0, 0);"
        ;;
    U)
        # Update: U id exit_code duration_ms — precmd hook fires after the
        # command line finished; $? is the line's exit and the shell measured
        # the duration between preexec and precmd (same wall clock). UUIDs
        # are never reused.
        # Bash records W and U back-to-back in separate fire-and-forget
        # connections (unlike zsh/fish, where the whole command runs between
        # them), so this UPDATE can win the race and find no row yet. Retry
        # briefly — either the row appears in the window or the W never
        # landed (shell died mid-command) and there is nothing to update.
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
        # Query: Q search query count — up to `count` commands whose text
        # contains every whitespace-separated term of `query` as a
        # subsequence. The server expands each term into a LIKE pattern with
        # % between its characters (so SQL is a superset of fzf's matcher),
        # escaping LIKE wildcards and quotes. Empty query = the newest
        # `count` commands. 0x1E/0x1F (sqlite3 -ascii framing hazards) and
        # \r are stripped; embedded newlines are escaped for single-line
        # display: `\` → `\\` and newline → `\n` (lossless — a command
        # containing a literal `\n` survives as `\\n`). The response is
        # NUL-framed, so the escaped rows are unambiguous; clients decode
        # `\\`→`\`, `\n`→newline on accept.
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

        # -ascii mode (0x1E row separator, 0x1F column separator) instead of
        # sqlite3's default newline-separated list output. The SELECT already
        # stripped 0x1E/0x1F from the display and escaped embedded newlines
        # (`\n`) plus backslashes (`\\`), so no embedded separator can tear
        # a row. Rows are emitted NUL-terminated — zero per-row forks, no
        # display escapes to reverse on the wire. mawk's printf eats a
        # literal \0 in the format, so rows are rejoined with 0x1E via ORS
        # and one tr pass converts that to NUL.
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
