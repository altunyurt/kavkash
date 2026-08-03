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
#   Server -> Client (Q only): one base64-encoded row per line (EOF-terminated).
#       Each payload is "display\n" (embedded newlines rendered as ⏎, framing
#       hazards 0x1E/0x1F stripped), so the client can batch-decode the whole
#       response and still get exactly one display line per row.
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
        id="$1"
        exit_code="$2"
        duration="$3"
        [ -n "$id" ] || exit 0
        case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
        case "$duration" in '' | *[!0-9]*) duration=0 ;; esac
        safe_id=$(printf '%s' "$id" | sed "s/'/''/g")
        sqlite3 "$db_file" "UPDATE history SET exit_code=$exit_code, duration_ms=$duration WHERE id='$safe_id';"
        ;;
    Q)
        # Query: Q search query count — up to `count` commands whose text
        # contains every whitespace-separated term of `query` as a
        # subsequence. The server expands each term into a LIKE pattern with
        # % between its characters (so SQL is a superset of fzf's matcher),
        # escaping LIKE wildcards and quotes. Empty query = the newest
        # `count` commands. The returned command is sanitized for
        # single-line display: 0x1E/0x1F (sqlite3 -ascii framing hazards)
        # and \r are dropped, embedded newlines become ⏎ (U+23CE).
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
                sql="SELECT REPLACE(REPLACE(REPLACE(REPLACE(command, char(30), ''), char(31), ''), char(10), char(9166)), char(13), '') FROM history $where ORDER BY id DESC LIMIT $count;"
                ;;
            *)
                exit 0
                ;;
        esac

        # -ascii mode (0x1E row separator, 0x1F column separator) instead of
        # sqlite3's default newline-separated list output. The SELECT already
        # stripped 0x1E/0x1F from the display, so no embedded separator can
        # tear a row. Each row is base64-encoded WITH a trailing newline
        # inside the payload: a client-side batch decode then reproduces
        # exactly one display line per row.
        sqlite3 -ascii "$db_file" "$sql" | LC_ALL=C awk '
        BEGIN { RS = "\036" }
        {
            row = $0
            sub(/\n$/, "", row)   # strip sqlite3 trailing newline artifact, if any
            if (row == "") next   # sqlite3 -ascii trailing-separator artifact; real rows are never empty
            b64cmd = "base64 -w0"
            printf "%s\n", row | b64cmd
            close(b64cmd)
            print ""
        }'
        ;;
esac
