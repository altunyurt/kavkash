# kavkash CLI — the main `kavkash` command

**Status: implemented.** The dispatcher lives on the `dispatcher`
branch (2 commits ahead of `main`, not yet released — `main` is at
v0.5.3; VERSION on this branch is still 0.5.3). This doc is the
design + the current state of the code; "Remaining work" at the end
is what is still outstanding.

The flat scripts in `~/.local/share/kavkash/` are internal (hook.sh,
processor.sh, query.sh, picker.sh, delete.sh, server.sh). User-facing
operations go through one entry point, like `atuin` / `git`: the
`kavkash` dispatch script with subcommands.

## Wiring

- `kavkash` lives at the install dir root; `~/.local/bin/kavkash` is a
  **symlink** to it, so `realpath "$0"` resolves the install dir (the
  pattern every existing script already uses). install.sh creates the
  symlink (KAVKASH_NO_SYMLINK opt-out), uninstall.sh removes it; the
  demo image adds `~/.local/bin` to PATH; release.yml bundles
  `kavkash` + `backup.sh`.
- Dispatch: `case "$1"` over subcommands; light ops are inline, heavy
  ops delegate to existing scripts (`import` → `import.sh`,
  `backup` → `backup.sh`). Internal scripts stay invisible. No args
  (and `help`/`-h`/`--help`) print the usage; unknown commands →
  usage + exit 2.

## Subcommands (current)

| Command              | What |
|----------------------|------|
| `kavkash status`     | daemon running? version, rows/distinct, db size |
| `kavkash info`       | data/db/socket/pid/log-file paths, version, installed revision, shell-hook status |
| `kavkash backup [dir]` | `.backup` snapshot of history.db (consistent, live-safe); keep newest 7, prune the rest |
| `kavkash restore FILE` | stop daemon → replace history.db → start (previous db kept as history.db.pre-restore) |
| `kavkash import [ARGS]` | `import.sh` passthrough (idempotent; install.sh passes --all) |
| `kavkash update`       | re-run the installer against the latest release (fetch install.sh from GitHub, same flow as the README one-liner) |
| `kavkash prune FLAGS [--mean-it]` | **dry run by default** — shows what would be removed, changes nothing; `--mean-it` applies it. Removes from the edges: `--oldest=N` / `--newest=N` (count), `--older-than=WHEN` / `--newer-than=WHEN` (age/date) |
| `kavkash compact`    | `PRAGMA integrity_check` then `VACUUM` |
| `kavkash dedup [OPTIONS] [--mean-it]` | collapse repeated commands to one row each; key/scope options: `--by-dir[=/PATH]`, `--by-date[=DAY]`, `--before=DAY`, `--after=DAY`; **dry run by default** — `--mean-it` applies |
| `kavkash stats`      | totals + top 10 commands (GROUP BY count) |
| `kavkash log [N]`    | tail `server.log` (default 50 lines) |
| `kavkash version`    | cat VERSION |

## Per-command details (as implemented)

- `status` — daemon via `kill -0 $(pidfile)`; version; `count(*)` /
  `count(DISTINCT command)` + db size via sqlite
- `info` — paths from includes.sh (data/db/socket/pid/log), `VERSION`,
  `INSTALLED_REVISION` first line, hook status (grep rc files for
  `source … functions.{bash,zsh,fish}` lines — comment-aware)
- `backup [dir]` — delegates to `backup.sh`: `sqlite3 .backup`
  (consistent even while the daemon writes — the DB is in `delete`
  journal mode, so a plain `cp` could catch a mid-transaction state),
  target `history.db.YYYY-MM-DD` in `dir` (default data dir), keeps the
  newest 7 snapshots
- `restore FILE` — validates FILE is a sqlite db → stops the daemon
  (systemd unit if installed, else pid TERM + wait) → moves the current
  db aside to `history.db.pre-restore` (never destroys the only copy) →
  copies FILE in → starts the daemon (systemd, else backgrounded
  server.sh)
- `import` — `exec "$_SCRIPT_DIR/import.sh" "$@"`
- `update` — fetches install.sh from `$KAVKASH_REPO` (default
  altunyurt/kavkash, same default as install.sh) via curl into a temp
  file, verifies the fetch succeeded (a pipe would mask curl's rc),
  then runs it — the installer overwrites KAV_DATA_HOME, re-creates the
  symlink, offers the re-import, and prints the daemon-restart note.
  Failure to fetch → `kav_die`, nothing changed, temp removed.
- `prune FLAGS [--mean-it]` — remove = the verb; **dry run by default**
  (validates everything, prints the would-remove count + spans,
  changes nothing); `--mean-it` applies. Spans union in one DELETE,
  `PRAGMA busy_timeout=5000`, then `VACUUM`. Bare `prune` (even with
  `--mean-it` and no spans) prints its own help + exit 2; invalid /
  unknown args die before touching the DB.
  - WHEN grammar is closed (no blind passthrough to GNU date):
    - durations: `30d` / `12h` / `8w` / `2mo` / `45m` / `30min` / `1y`
      — always "N unit ago", inherently past (`45m` and `30min` are
      minutes, `2mo` months, `1y` years)
    - dates: strict whitelist `YYYY-MM-DD`, `YYYY-MM-DD HH:MM[:SS]`,
      `yesterday`, `today` — nothing else reaches `date -d` (its magic
      words like "next tuesday" / "5pm" / "1 week" can resolve to
      future times); `yesterday`/`today` are matched before the `*y`
      unit branch (they end in "y")
    - future boundaries are refused (a future `--older-than` line would
      delete everything; use `--newest=N` for recent cleanup)
    - local timezone, matching the ns ids
- `compact` — `integrity_check` must be `ok`, then `VACUUM`
- `dedup [OPTIONS] [--mean-it]` — the picker already displays one row per
  command (GROUP BY); dedup makes what's STORED match. Default: one row
  per distinct command across the whole table (keeps the newest
  occurrence, `MAX(id)` — the picker's ordering). The dedup KEY extends:
  `--by-dir` (+ cwd), `--by-date` (+ local calendar day via
  `strftime('%F', id/1e9, 'unixepoch', 'localtime')`), both. The SCOPE
  narrows which rows are eligible — everything outside is never touched:
  `--by-dir=/PATH` (repeatable, OR), `--by-date=DAY`,
  `--before=WHEN`/`--after=WHEN` (prune's full WHEN grammar — durations
  `30d`/`12h`/`8w`/`2mo`/`45m`/`30min`/`1y`, `yesterday`/`today`, strict
  `YYYY-MM-DD [HH:MM[:SS]]` — resolved to the local day, so `--after=30d`
  means "days after the day 30 days ago"; band between when both). The
  scope gates BOTH the outer DELETE and the kept-set
  subquery, so out-of-scope rows can't be caught by `NOT IN`.
  `--before`/`--after` are mutually exclusive with `--by-date`; a bare
  `--by-dir` cannot combine with `--by-dir=VALUE`. `--by-date` is strict
  `YYYY-MM-DD`; `--before`/`--after` take prune's full WHEN grammar
  (resolved to a day). Dry run shows the scoped
  group count; `--mean-it` applies; VACUUM after; idempotent.
- `stats` — totals line + top 10 by usage
- `log [N]` — `tail -n N "$KAV_RUNTIME_DIR/server.log"`

## Notes

- **Dedup is mostly automatic** — save-time consecutive collapse and
  display-time `GROUP BY`; `kavkash dedup --mean-it` is the manual
  maintenance command that collapses the *stored* table (optionally per
  directory / day / range via `--by-dir`, `--by-date`, `--before`,
  `--after`) to match.
- `backup`/`restore` cover the real data-loss risk: a week of active
  history far exceeds what the capped shell files (~/.bash_history
  2000, zsh 1000) retain, and exit codes/durations/sessions only ever
  live in history.db.

## Remaining work

1. **Release process** — merge `dispatcher` → `main`, bump VERSION →
   0.5.4, tag `v0.5.4` (repo convention), then push (nothing has been
   pushed yet).
2. **uninstall.sh `--purge` backup hook** — from the backup design:
   before deleting history.db on purge, write an automatic backup
   (never destroy the only copy of live-recorded history). Not yet
   implemented (uninstall.sh currently has no backup step).
3. Deliberately out of scope (decided during design): no periodic
   backup timer, no config file.

## Test plan (executed)

- Symlink → `realpath` resolution from any CWD ✓
- Every subcommand against a scratch install (XDG overrides): status /
  info / version correct ✓; backup creates + prunes to 7 ✓; restore
  round-trip (rows back, pre-restore kept, daemon restarted) ✓;
  prune dry-run vs `--mean-it` counts match ✓; compact/stats on seeded
  data ✓; `import` passthrough ✓
- Error paths: unknown command → usage + exit 2 ✓; restore with a
  missing/invalid file → `kav_die` ✓; prune bare / bad values / magic
  words / future dates → die or help, DB untouched ✓
- install/uninstall symlink create/remove (syntax-checked; live
  install verified via the symlink) ✓
