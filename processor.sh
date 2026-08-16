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
#                           BEFORE the LIMIT (filtering after the LIMIT
#                           would miss matching rows). cwd matches the
#                           dir + subtree; "/" is a no-op.
# Rows carry raw command text — multi-line commands pass through intact
# (fzf renders them natively); only 0x1E/0x1F (sqlite3 -ascii hazards)
# and \r are stripped. NUL framing is safe: command text can never
# contain NUL.
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
        # Trailing whitespace off the stored command — "ls " and "ls<TAB>"
        # must be "ls": otherwise the picker's GROUP BY and dedup keep
        # each variant as its own row (they'd survive dedup forever).
        # A command that is only whitespace is nothing — drop it.
        cmd=$(printf '%s' "$cmd" | sed 's/[ \t\r]*$//')
        [ -n "$cmd" ] || exit 0
        # Daily snapshot on the first command of a day (fire-and-forget:
        # the response id must not be delayed, and stdout is the response
        # channel — silenced; stderr still reaches the server log).
        ( kav_maybe_backup "$_SCRIPT_DIR/backup.sh" > /dev/null ) &
        cwd="$2"
        id="$3"
        session="$4"
        # id must be an integer (INTEGER PRIMARY KEY); drop anything else
        # (garbage on the wire).
        case "$id" in '' | *[!0-9]*) exit 0 ;; esac

        safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
        safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
        safe_session=$(printf '%s' "$session" | sed "s/'/''/g")
        # Consecutive-repeat collapse: a W whose (command, cwd, session)
        # matches the latest row updates that row in place — the row
        # becomes the newest occurrence (id = this command's timestamp;
        # exit/duration still pending the U) — instead of inserting a
        # duplicate. IS handles empty-session (NULL) matching. A shell
        # that dies mid-command leaves exit 0 / duration 0; ids are never
        # reused; kav_db's .timeout makes concurrent writers (several
        # terminals at once) wait for the lock instead of failing with
        # SQLITE_BUSY.
        changed=$(kav_db "$db_file" "UPDATE history SET id=$id, exit_code=0, duration_ms=0, session=NULLIF('$safe_session','') WHERE id=(SELECT id FROM history ORDER BY id DESC LIMIT 1) AND command='$safe_cmd' AND cwd='$safe_cwd' AND session IS NULLIF('$safe_session',''); SELECT changes();" 2> /dev/null | tail -1)
        case "$changed" in
            *[1-9]*) : ;;   # collapsed the previous consecutive repeat
            *)
                # Insert with a PK-collision retry: ids are client-minted
                # ns timestamps; on ms-resolution fallback clocks two
                # commands in the same ms collide and the plain INSERT
                # silently fails. Bump to the next free id (the row's
                # timestamp ends up a few ns off — irrelevant).
                n=0
                while ! kav_db "$db_file" "INSERT INTO history (id, command, cwd, exit_code, duration_ms, session) VALUES ($id, '$safe_cmd', '$safe_cwd', 0, 0, NULLIF('$safe_session', ''));" 2> /dev/null; do
                    id=$((id + 1))
                    n=$((n + 1))
                    [ "$n" -lt 100 ] || break
                done
                ;;
        esac
        ;;
    U)
        # Update: precmd reports $? and shell-measured duration for the id.
        # Bash fires W and U back-to-back in separate fire-and-forget
        # connections (zsh/fish run a whole command between them), so the U
        # can win the race and find no row yet — retry briefly. An
        # optional 4th field (the command, trimmed like W) pins the update
        # to the right row: a W that bumped its id on a collision lives at
        # a different id than the shell holds, and a plain id update would
        # overwrite the row that took the original id.
        id="$1"
        exit_code="$2"
        duration="$3"
        cmd="${4:-}"
        [ -n "$id" ] || exit 0
        case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
        case "$duration" in '' | *[!0-9]*) duration=0 ;; esac
        safe_id=$(printf '%s' "$id" | sed "s/'/''/g")
        cmd_match=""
        if [ -n "$cmd" ]; then
            cmd=$(printf '%s' "$cmd" | sed 's/[ \t\r]*$//')
            safe_cmd=$(printf '%s' "$cmd" | sed "s/'/''/g")
            cmd_match=" AND command='$safe_cmd'"
        fi
        n=0
        while [ "$n" -lt 5 ]; do
            changed=$(kav_db "$db_file" "UPDATE history SET exit_code=$exit_code, duration_ms=$duration WHERE id='$safe_id'$cmd_match; SELECT changes();" 2> /dev/null | tail -1)
            case "$changed" in *[1-9]*) break ;; esac
            n=$((n + 1))
            sleep 0.01 2> /dev/null || break
        done
        ;;
    Q)
        # Query: newest `count` DISTINCT commands matching the scope at
        # `offset`, NUL-framed raw rows (GROUP BY command — one row per
        # unique command, ordered by its newest occurrence). QUERY is a
        # prefix filter: the Up/Down stepper passes the typed line and
        # gets only commands starting with it; empty = no filter (the
        # picker sends an empty query and fzf filters client-side).
        # cwd/session scope (empty = no filter) applies BEFORE the LIMIT:
        # the result is the newest N distinct commands matching the scope.
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
            sc=$(printf '%s' "$cwd" | sed "s/'/''/g")
            # the dir itself + subtree; "/" (everything) is a no-op above
            where="(cwd = '$sc' OR cwd LIKE '$sc/%')"
        fi
        if [ -n "$session" ]; then
            ss=$(printf '%s' "$session" | sed "s/'/''/g")
            where="${where:+$where AND }session = '$ss'"
        fi
        if [ -n "$query" ]; then
            # Anchored prefix match, case-insensitive (NOCASE). substr
            # avoids LIKE wildcards: % and _ in the prefix are literal.
            q=$(printf '%s' "$query" | sed "s/'/''/g")
            where="${where:+$where AND }substr(command,1,length('$q')) = '$q' COLLATE NOCASE"
        fi
        # Dedup: GROUP BY command folds interspersed repeats (e.g.
        # hundreds of "ls") into one row per distinct command, ordered by
        # each command's newest occurrence (MAX(id)); consecutive repeats
        # were already collapsed at save time (W). The scope WHERE applies
        # before the GROUP, so the result is the newest N distinct commands
        # matching the scope. The payload is command + its MAX(id) so the
        # picker can act on the row (delete) while displaying only the
        # command (fzf --with-nth).
        sql="SELECT REPLACE(REPLACE(REPLACE(command, char(30), ''), char(31), ''), char(13), '') || char(31) || MAX(id) FROM history${where:+ WHERE $where} GROUP BY command ORDER BY MAX(id) DESC LIMIT $count OFFSET $offset;"

        # sqlite3 -ascii (0x1E rows / 0x1F cols); the SELECT already stripped
        # those hazards, so no embedded separator can tear a row. Rows are
        # rejoined with 0x1E via ORS and one tr converts to NUL (mawk printf
        # eats a literal \0 in formats).
        # kav_db: the dot-command sets the lock wait on this connection
        # and prints nothing — a PRAGMA would echo its value as a row
        # into the picker stream.
        kav_db -ascii "$db_file" "$sql" | LC_ALL=C awk '
        BEGIN { RS = "\036"; ORS = "\036" }
        {
            row = $0
            sub(/\n$/, "", row)   # strip sqlite3 trailing newline artifact, if any
            if (row == "") next   # sqlite3 -ascii trailing-separator artifact; real rows are never empty
            print row
        }' | tr '\036' '\000'
        ;;
    D)
        # Delete: D id — permanently remove a command (all its rows, so
        # the deduplicated picker entry disappears). The id anchors the
        # command: the delete targets every row whose command matches the
        # one found at that id. Unknown ids delete nothing.
        id="$1"
        case "$id" in '' | *[!0-9]*) exit 0 ;; esac
        kav_db "$db_file" "DELETE FROM history WHERE command = (SELECT command FROM history WHERE id=$id);"
        ;;
esac
