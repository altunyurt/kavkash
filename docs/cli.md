# kavkash CLI plan — a main `kavkash` command (unimplemented)

The flat scripts in `~/.local/share/kavkash/` are internal (hook.sh,
processor.sh, query.sh, picker.sh, delete.sh, server.sh). User-facing
operations need one entry point, like `atuin` / `git`: a `kavkash`
dispatch script with subcommands. Implemented step by step from this
plan.

## Wiring

- `kavkash` lives at the install dir root; `~/.local/bin/kavkash` is a
  **symlink** to it, so `realpath "$0"` resolves the install dir (the
  pattern every existing script already uses). install.sh creates the
  symlink, uninstall.sh removes it; the demo image adds `~/.local/bin`
  to PATH.
- Dispatch: `case "$1"` over subcommands; light ops are inline, heavy
  ops delegate to the existing scripts (`import` → `import.sh`,
  `backup` → `backup.sh`, …). Internal scripts stay invisible.

## Subcommands

| Command              | What |
|----------------------|------|
| `kavkash status`     | daemon running? db rows/size, socket, version |
| `kavkash info`       | install dir, db/socket/pid paths, installed revision, shell-hook status |
| `kavkash backup [dir]` | `.backup` snapshot of history.db (consistent, live-safe); keep newest 7, prune the rest |
| `kavkash restore FILE` | stop daemon → replace history.db → start |
| `kavkash import`     | `import.sh --all` (idempotent) |
| `kavkash prune [N]`  | keep newest N commands + `VACUUM` (currently a hand-typed README snippet; default 5000) |
| `kavkash compact`    | `VACUUM` + `PRAGMA integrity_check` |
| `kavkash stats`      | totals + top commands (the GROUP BY dedup already exists) |
| `kavkash log`        | tail `server.log` |
| `kavkash version`    | cat VERSION |

Notes:

- **No `kavkash dedup`** — dedup is already automatic (save-time
  consecutive collapse + query-time GROUP BY); the manual maintenance
  command is `compact`.
- `backup`/`restore` cover the real data-loss risk: a week of active
  history far exceeds what the capped shell files (~/.bash_history
  2000, zsh 1000) retain, and exit codes/durations/sessions only ever
  live in history.db.
- Backups and restores use `sqlite3 .backup` (consistent even while the
  daemon writes; the DB is in `delete` journal mode, so a plain `cp`
  could catch a mid-transaction state). Restore requires the daemon
  stopped.

## Implementation plan — the `kavkash` base script

One self-contained POSIX-sh dispatcher at the install-dir root,
symlinked onto PATH:

```
~/.local/share/kavkash/kavkash        ← the real script
~/.local/bin/kavkash → (symlink)      ← install.sh creates, uninstall.sh removes
```

It sources `includes.sh` via `dirname -- "$(realpath -- "$0")"` (the
existing pattern — the symlink resolves back to the install dir, so
`KAV_DATA_HOME`/`KAV_DB_FILE`/`KAV_SOCK_FILE`/`KAV_PID_FILE` come from
includes.sh). All commands are functions inside the one file
(`kav_cmd_*`), with the heavy ops delegating where a script already
exists (`import` → `import.sh`).

```
#!/bin/sh
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"
set -eu

usage() { … }                        # table above

kav_cmd_status() { … }
kav_cmd_info() { … }
… (one function per subcommand)

cmd=${1:-help}; shift 2>/dev/null || true
case "$cmd" in
    status)  kav_cmd_status ;;
    info)    kav_cmd_info ;;
    backup)  kav_cmd_backup "$@" ;;
    restore) kav_cmd_restore "$@" ;;
    import)  exec "$SCRIPT_DIR/import.sh" "$@" ;;   # pass-through (default --all)
    prune)   kav_cmd_prune "$@" ;;
    compact) kav_cmd_compact ;;
    stats)   kav_cmd_stats ;;
    log)     kav_cmd_log "$@" ;;
    version) cat "$KAV_DATA_HOME/VERSION" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
```

Per-command behavior:

- `status` — daemon: `kill -0 $(pidfile)` + socket exists; `version`;
  `rows/distinct` + db size via sqlite
- `info` — paths (data/db/socket/pid), `VERSION`, `INSTALLED_REVISION`,
  hook status (grep rc files for the `source` lines)
- `backup [dir]` — delegate to `backup.sh` (`.backup` + keep-newest-7)
- `restore FILE` — validate FILE is a sqlite db → stop daemon (systemctl
  unit if present, else pid TERM + wait) → move current db aside to
  `history.db.pre-restore` → copy FILE in → start daemon
- `import` — `exec import.sh "$@"`
- `prune [N]` — default 5000, refuse 0; `DELETE … WHERE id NOT IN
  (SELECT id … ORDER BY id DESC LIMIT N); VACUUM;`
- `compact` — `PRAGMA integrity_check` then `VACUUM`
- `stats` — totals + top 10 commands (GROUP BY count)
- `log [N]` — `tail -n N server.log` (default 50)
- `version` — `cat VERSION`

Wiring changes:

- install.sh — after `install_files`: `install -d "$HOME/.local/bin"` +
  `ln -sfn "$KAV_DATA_HOME/kavkash" "$HOME/.local/bin/kavkash"`; mention
  `kavkash status` in the summary
- uninstall.sh — `rm -f "$HOME/.local/bin/kavkash"`
- demo.sh — Dockerfile gains `ENV PATH="/root/.local/bin:$PATH"`
- release.yml — add `kavkash` to the bundle

Test plan:

- Symlink → `realpath` resolution works from any CWD
- Each subcommand against a scratch install (`XDG_DATA_HOME` override):
  status/info/version correct; backup creates + prunes to 7; restore
  round-trip (seeded DB → backup → wipe → restore → rows back, daemon
  restarted); prune/compact/stats on a seeded DB; `import` passes args
- Error paths: unknown command → usage + exit 2; `restore` with a
  missing/invalid file → `kav_die`; `prune 0` refused
- install/uninstall symlink create/remove (scratch `~/.local/bin`)

Order of work:

1. `kavkash` dispatcher with the inline commands (status/info/version/
   log/stats/prune/compact/import) — no `backup`/`restore` yet
2. `backup.sh` + the `backup`/`restore` cases
3. install/uninstall/demo/release wiring
4. Tests + docs
