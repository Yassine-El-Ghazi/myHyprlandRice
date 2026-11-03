# Wallpaper selection and state

The Waybar button, Super+Ctrl+W, `myhyprctl wallpaper`, and the Quickshell
Welcome/Sidebar buttons open a repository Rofi picker. The historical
`hypr/scripts/waypaper.sh` filename remains a compatibility entry point, but
does not start Waypaper. The terminal `wallpaper` alias still uses Fzf.
Picker rows display escaped paths; selection returns an index or a NUL-delimited
path rather than interpreting the displayed text as a filename or command.
Both pickers use the same repository file list, including names with trailing
newlines; image-extension filtering never changes the selected path's bytes.

All application goes through `hypr/scripts/wallpaper.sh` and `wallpaper.py`:

1. Acquire the user-owned `~/.cache/myhypr/wallpaper-pipeline.lock` with `flock`.
2. Read authoritative state and select the current original/effect under the lock.
3. Validate and snapshot the original file; prepare any effect before application.
4. Prepare and fsync a new state file in the state directory.
5. Apply the final asset using one absolute-path `awww img` call across all outputs.
6. On backend success, atomically rename the new state and fsync its directory.
7. Generate Matugen colors from the applied asset, update wallpaper assets,
   refresh panels, and release the lock.

The cache named `current_wallpaper` is now a versioned JSON object containing
`original`, `applied`, and `effect`. JSON escapes control characters and surrogate
escapes, preserving filesystem bytes, including embedded/trailing newlines and
non-UTF-8 names. Consumers parse JSON directly; it is never sourced or evaluated.
`original` is the selected identity; `applied` is an immutable snapshot or generated
effect asset. State and effect preference advance together in one atomic write.
The old `wallpaper-effect.sh` setting is only a seed when no repository state exists.

Adaptive colors use Matugen's first-ranked dominant source color explicitly
(`--source-color-index 0`), preserving its older default rather than prompting
for a source color on Matugen 4.2. Transaction helpers receive no interactive
stdin. Matugen also supports `source_color_index = 0` under `[config]`, but the
pipeline supplies its own option so standalone Matugen preferences remain alone.

All readers, including GTK preference changes, coordinate through the same lock.
Overlapping requests are linearized by lock acquisition: the last successful
transaction in that order wins. Effect requests resolve the current original
after acquiring the lock, so they cannot capture and later restore an old choice.
Synchronous backend/color/asset subprocesses retain the lock and are bounded by
Coreutils `timeout`; detached panel processes do not inherit it. A lock file can
remain on disk after exit; its presence does not mean the lock is held.

## Commands and restore

```bash
~/.config/hypr/scripts/wallpaper.sh --wallpaper '/absolute/image path.png'
~/.config/hypr/scripts/wallpaper.sh --random
~/.config/hypr/scripts/wallpaper.sh --effect blackwhite
~/.config/hypr/scripts/wallpaper.sh --effect off
~/.config/hypr/scripts/wallpaper.sh --restore
~/.config/hypr/scripts/wallpaper.sh --refresh
```

Random selection and all pickers use `myhypr/settings/wallpaper-folder`, falling
back to `~/.config/myhypr/wallpapers`. Super+Alt+W toggles the existing repository
automation worker. There is no repository-launched Waypaper slideshow/daemon.
The repository deliberately supports a single global wallpaper across outputs,
rather than separate per-monitor choices; one selection therefore causes one
backend application, state publication, and set of global refreshes.

Startup restore reads only repository state. With no state, it applies
`~/.config/myhypr/wallpapers/default.jpg`, using the seeded effect. Missing files,
invalid state, effect failure, or backend failure produce an error without
publishing a successful selection. Old line-based caches are not adopted:
an explicit valid selection safely replaces an old/malformed cache after backend
success, while `--restore` and effect-only requests reject it. No Waypaper saved
selection is used for bootstrap, migration, restore, or automation.
When a committed applied snapshot exists, restore reuses those verified bytes
even if the original source has moved or changed. If the snapshot was deleted,
restore must regenerate and successfully apply the original before updating state.
Effect reload deliberately regenerates from the current original instead.

## Failure and retry behavior

Effect generation happens before backend application. A generation failure leaves
the previous wallpaper and state alone. A rejected backend command does not
advance state, effect preference, or Matugen colors.

After backend success, Matugen/panel/asset errors are non-transactional: the
wallpaper and committed state remain current, an error is reported, and
`--refresh` retries dependent work without applying another wallpaper. Dock
startup failures are reported when observed. Startup of a long-running panel
is not a guarantee that it will continue running.

Default diagnostics identify the failed stage and exit status or system error
without printing source paths, snapshot paths, raw command arguments, or raw
dependency output. Successful application prints `Wallpaper applied successfully.`
Use `--verbose` deliberately to see dependency output and exception tracebacks;
this may disclose private paths and should be reviewed before sharing. In this
mode, later dock output is retained in the user-only
`~/.cache/myhypr/wallpaper-panels.log`. Default operation does not create or append
that raw log. Independent applications may maintain their own logs separately.
The interactive pickers and explicitly requested NUL-delimited `--list` output
are selection interfaces, not diagnostics, and necessarily expose image choices.

State files are fully written and fsynced before application. If final state
publication fails, the pipeline attempts to reapply the previous committed asset.
Backend application and filesystem publication cannot form a hardware-atomic
transaction: a crash between them, a failed rollback, or storage failure during
the first application can require `--restore` to re-establish the last committed
wallpaper (or bootstrap default). No prepared-but-uncommitted state is trusted.
Retained snapshot/effect assets support rollback; automatic garbage collection
is intentionally not part of this change.

## External Waypaper boundary

Repository launchers do not start Waypaper, modify its state/configuration, or
spawn any Waypaper child. This avoids its failure-status, newline-persistence,
per-monitor callback, and slideshow semantics entirely. Changes to Waypaper's
backend interface cannot change the repository transaction.

An independently launched Waypaper can still change the desktop outside this
pipeline. Its selected state/UI may disagree with repository state and its own
slideshow/settings remain its responsibility. Before using an older external
installation, close existing instances and clear any legacy `post_command` in
`~/.config/waypaper/config.ini`. Repository defaults keep that callback empty.
Repository restore always reapplies the last verified repository selection.
