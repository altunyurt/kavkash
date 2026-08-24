# backup.sh [DIR] — consistent snapshot via sqlite .backup (live-safe
# even mid-transaction, unlike a plain cp on a WAL db).
# Target: $KAV_DATA_HOME/history.db.YYYY-MM-DD.HH-MM-SS (name order ==
# time order); keeps the newest 7.
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"
set -eu

kav_have sqlite3 || kav_die 'backup: sqlite3 is required'
[ -f "$KAV_DB_FILE" ] || kav_die "backup: no database at $KAV_DB_FILE"

dir="${1:-$KAV_DATA_HOME}"
[ -d "$dir" ] || kav_die "backup: not a directory: $dir"

stamp=$(date +%F.%H-%M-%S)
target="history.db.$stamp"
# Same-second runs would share a name — bump a counter (-1, -2, ...).
n=0
while [ -e "$dir/$target" ]; do
    n=$((n + 1))
    target="history.db.$stamp-$n"
done
(cd "$dir" && kav_db "$KAV_DB_FILE" ".backup '$target'") || kav_die 'backup: sqlite .backup failed'
printf 'backed up %s -> %s/%s\n' "$KAV_DB_FILE" "$dir" "$target"

# Prune to the newest 7 snapshots.
count=0
for old in $(ls -1 "$dir"/history.db.* 2> /dev/null | sort -r); do
    count=$((count + 1))
    if [ "$count" -gt 7 ]; then
        rm -f "$old"
        printf 'pruned  %s\n' "$old"
    fi
done
