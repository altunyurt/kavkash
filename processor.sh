#!/usr/bin/dash
# processor.sh - Netstring protocol handler
# Source includes.sh relative to THIS script (socat EXEC may have any CWD).
_SCRIPT_DIR=$(dirname -- "$(realpath -- "$0")")
. "$_SCRIPT_DIR/includes.sh"
#
# Wire protocol: concatenated netstrings ("len:payload,").
#   W cmd cwd id session    write (preexec; id = ns-since-epoch = row
#                           timestamp, session = per-shell token, '' = none)
#   U id exit_code dur_ms [cmd]
#                           update (precmd; the optional command pins
#                           the update to the right row when the id was
#                           bumped on a collision)
#   Q search query count cwd session
#                           query -> NUL-separated rows; cwd/session scope
#                           BEFORE the LIMIT. cwd matches the dir +
#                           subtree; "/" is a no-op.
# Rows carry raw command text — multi-line commands pass through intact;
# only 0x1E/0x1F (sqlite3 -ascii hazards) and \r are stripped. NUL
# framing is safe: command text can never contain NUL.

# Bound input: a client that never sends a valid netstring would
# otherwise buffer unboundedly in the awk parser.
INPUT=$(head -c 2097152)
[ -z "$INPUT" ] && exit 0

# Netstring parser: decodes "length:payload," into base64 fields, one
# per line — base64 is newline/NUL-free, so fields survive the $(...)
# round trip intact. Max payload 1MB (OOM guard).
FIELDS=$(printf '%s' "$INPUT" | LC_ALL=C awk '
BEGIN { RS = "\0" }  # treat entire input as one record
{
    data = $0; pos = 1; len = length(data)
    while (pos <= len) {
        colon = index(substr(data, pos), ":")   # length:payload,
        if (colon == 0) break                     # no colon = malformed
        colon += pos - 1                          # absolute position

        lenstr = substr(data, pos, colon - pos)   # digits, no leading zeros
        if (lenstr !~ /^(0|[1-9][0-9]*)$/) break
        if (lenstr + 0 > 1048576) break            # max 1MB payload

        payload_len = lenstr + 0
        value = substr(data, colon + 1, payload_len)
        if (length(value) != payload_len) break   # truncated payload

        term = colon + 1 + payload_len
        if (substr(data, term, 1) != ",") break    # missing comma

        # emit field as base64 on its own line (newline-safe framing)
        b64cmd = "base64 -w0"
        printf "%s", value | b64cmd
        close(b64cmd)
        print ""

        pos = term + 1                             # advance
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
        # Trailing whitespace off the stored command — "ls " and "ls<TAB>"
        # must be "ls": otherwise the picker's GROUP BY keeps each variant
        # as its own row. A command that is only whitespace is nothing.
        cmd=$(printf '%s' "$cmd" | sed 's/[ \t\r]*$//')
        [ -n "$cmd" ] || exit 0
        # Daily snapshot on the first command of a day — fire-and-forget
        # (stdout is the response channel; stderr reaches the server log).
        ( kav_maybe_backup "$_SCRIPT_DIR/backup.sh" > /dev/null ) &
        kav_rotate_log
        cwd="$2"
        id="$3"
        session="$4"
        case "$id" in '' | *[!0-9]*) exit 0 ;; esac   # INTEGER PRIMARY KEY

        safe_cmd=$(kav_sql_quote "$cmd")
        safe_cwd=$(kav_sql_quote "$cwd")
        safe_session=$(kav_sql_quote "$session")
        # Consecutive-repeat collapse: a W matching the latest row
        # (command, cwd, session) updates that row in place instead of
        # inserting a duplicate — the row becomes the newest occurrence.
        # IS handles empty-session (NULL) matching; a shell that dies
        # mid-command leaves exit 0 / duration 0; kav_db_w's .timeout
        # makes concurrent writers wait for the lock (no SQLITE_BUSY).
        changed=$(kav_db_w "$KAV_DB_FILE" "UPDATE history SET id=$id, exit_code=0, duration_ms=0, session=NULLIF('$safe_session','') WHERE id=(SELECT id FROM history ORDER BY id DESC LIMIT 1) AND command='$safe_cmd' AND cwd='$safe_cwd' AND session IS NULLIF('$safe_session',''); SELECT changes();" 2> /dev/null | tail -1)
        case "$changed" in
            *[1-9]*) : ;;   # collapsed the previous consecutive repeat
            *)
                # Insert with a PK-collision retry: ids are client-minted
                # ns timestamps; on ms-resolution fallback clocks two
                # commands in the same ms collide and the plain INSERT
                # silently fails. Bump to the next free id.
                n=0
                while ! kav_db_w "$KAV_DB_FILE" "INSERT INTO history (id, command, cwd, exit_code, duration_ms, session) VALUES ($id, '$safe_cmd', '$safe_cwd', 0, 0, NULLIF('$safe_session', ''));" 2> /dev/null; do
                    id=$((id + 1))
                    n=$((n + 1))
                    [ "$n" -lt 100 ] || break
                done
                [ "$n" -lt 100 ] || kav_log "write failed after $n id-bump retries (insert error)"
                ;;
        esac
        ;;
    U)
        # Update: precmd reports $? and shell-measured duration for the id.
        # Bash fires W and U back-to-back in separate fire-and-forget
        # connections (zsh/fish run a whole command between them), so the U
        # can win the race and find no row yet — retry briefly. The
        # optional 4th field (the command, trimmed like W) pins the update:
        # a W that bumped its id on a collision lives at a different id
        # than the shell holds, and a plain id update would overwrite the
        # row that took the original id.
        id="$1"
        exit_code="$2"
        duration="$3"
        cmd="${4:-}"
        [ -n "$id" ] || exit 0
        case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
        case "$duration" in '' | *[!0-9]*) duration=0 ;; esac
        safe_id=$(kav_sql_quote "$id")
        cmd_match=""
        if [ -n "$cmd" ]; then
            cmd=$(printf '%s' "$cmd" | sed 's/[ \t\r]*$//')
            safe_cmd=$(kav_sql_quote "$cmd")
            cmd_match=" AND command='$safe_cmd'"
        fi
        n=0
        while [ "$n" -lt 5 ]; do
            changed=$(kav_db_w "$KAV_DB_FILE" "UPDATE history SET exit_code=$exit_code, duration_ms=$duration WHERE id='$safe_id'$cmd_match; SELECT changes();" 2> /dev/null | tail -1)
            case "$changed" in *[1-9]*) break ;; esac
            n=$((n + 1))
            sleep 0.01 2> /dev/null || break
        done
        ;;
    Q)
        # Query: newest `count` DISTINCT commands matching the scope at
        # `offset`, NUL-framed rows. QUERY is an anchored prefix filter
        # (empty = no filter — the picker sends an empty query and fzf
        # filters client-side). cwd/session scope applies BEFORE the LIMIT.
        action="$1"
        query="$2"
        count="$3"
        cwd="$4"
        session="$5"
        offset="$6"
        case "$count" in '' | *[!0-9]*) count=10000 ;; esac
        [ "$count" = "0" ] && count=-1   # 0 = all rows (SQLite LIMIT -1)
        case "$offset" in '' | *[!0-9]*) offset=0 ;; esac
        case "$action" in
            search) ;;
            *) exit 0 ;;
        esac
        where=""
        if [ -n "$cwd" ] && [ "$cwd" != "/" ]; then
            sc=$(kav_sql_quote "$cwd")
            # the dir itself + subtree; "/" (everything) is a no-op above
            where="(cwd = '$sc' OR cwd LIKE '$sc/%')"
        fi
        if [ -n "$session" ]; then
            ss=$(kav_sql_quote "$session")
            where="${where:+$where AND }session = '$ss'"
        fi
        if [ -n "$query" ]; then
            # Anchored prefix match, case-insensitive (NOCASE). substr
            # avoids LIKE wildcards: % and _ in the prefix are literal.
            q=$(kav_sql_quote "$query")
            where="${where:+$where AND }substr(command,1,length('$q')) = '$q' COLLATE NOCASE"
        fi
        # Dedup: the self-join picks each distinct command's newest row
        # (MAX(id)) within the scope, so the payload carries that last
        # run's exit code and duration — formatted as metadata in the awk
        # below. Consecutive repeats were already collapsed at save time.
        sql="SELECT REPLACE(REPLACE(REPLACE(h.command, char(30), ''), char(31), ''), char(13), '') || char(31) || h.id || char(31) || h.exit_code || char(31) || h.duration_ms FROM history h JOIN (SELECT command, MAX(id) AS mid FROM history${where:+ WHERE $where} GROUP BY command) m ON h.id = m.mid ORDER BY h.id DESC LIMIT $count OFFSET $offset;"

        # sqlite3 -ascii (0x1E rows / 0x1F cols); the SELECT already
        # stripped those hazards. Rows are rejoined with 0x1E via ORS and
        # one tr converts to NUL (mawk printf eats a literal \0).
        # Field 1 = "dur ✓/✗ age\x1fcommand\x1fid": one separator byte
        # for every field — fzf's --delimiter/--nth split on it, so
        # matching (--nth 2) sees only the command, and the shells cut
        # at it. Commands never contain \x1f (stripped in the SELECT).
        kav_db -ascii "$KAV_DB_FILE" "$sql" | LC_ALL=C awk -v NOW="$(date +%s%N 2> /dev/null || echo 0)" '
        BEGIN { RS = "\036"; ORS = "\036" }
        {
            row = $0
            sub(/\n$/, "", row)   # strip sqlite3 trailing newline artifact, if any
            if (row == "") next   # sqlite3 -ascii trailing-separator artifact; real rows are never empty
            n = split(row, f, "\037")   # command \x1f id \x1f exit \x1f dur
            if (n < 4) next
            dur = f[4]
            if (dur < 1000) d = dur "ms"
            else if (dur < 60000) d = sprintf("%.1fs", dur / 1000)
            else if (dur < 3600000) d = int(dur / 60000) "m"
            else d = int(dur / 3600000) "h"
            age = int((NOW - f[2]) / 1000000000)
            # Adaptive units (s m h d w mo y), bounded so old commands
            # keep a short age field.
            if (age < 60) a = age "s"
            else if (age < 3600) a = int(age / 60) "m"
            else if (age < 86400) a = int(age / 3600) "h"
            else {
                days = int(age / 86400)
                if (days < 8) a = days "d"
                else if (days < 30) a = int(days / 7) "w"
                else if (days < 365) a = int(days / 30) "mo"
                else a = int(days / 365) "y"
            }
            mark = (f[3] == "0") ? "✓" : "✗"   # plain text: fzf strips item ANSI codes
            # Metadata leads, as its own \x1f field; the trailing space
            # keeps it off the command text. Matching (--nth 2) sees
            # only the command field.
            meta = sprintf(" %-6s %s %-4s ", d, mark, a)
            print meta "\037" f[1] "\037" f[2]   # print (not printf) so ORS\x1e frames the row
        }' | tr '\036' '\000'
        ;;
    D)
        # Delete: D id — permanently remove a command (all its rows, so
        # the deduplicated picker entry disappears). The id anchors the
        # command: delete every row whose command matches the one at id.
        # Unknown ids delete nothing.
        id="$1"
        case "$id" in '' | *[!0-9]*) exit 0 ;; esac
        kav_db_w "$KAV_DB_FILE" "DELETE FROM history WHERE command = (SELECT command FROM history WHERE id=$id);"
        ;;
esac
