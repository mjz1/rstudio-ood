# Changelog

Notable changes, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

**`0.9.x` is pre-release**: the app is public but not yet announced to users, so
breaking changes are still cheap. `1.0.0` will mark the release to the lab.

Update an existing install to the latest release with:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/master/install.sh | bash -s -- --app-only
```

## [Unreleased]

_Nothing yet._

## [0.9.4] - 2026-07-13

### Added

- The update notice now **links to this changelog**, in the launch form (a
  clickable "See what changed"), the R console, and `sync_images`. A version
  number tells you nothing; what changed is what lets you decide whether you
  want it.
- Releases are published on GitHub with their changelog section as the release
  notes, so tags are readable rather than bare.

## [0.9.3] - 2026-07-13

### Added

- The update notice now appears **in the launch form** — the first thing every
  user sees — not only in the R console and `sync_images`. Consumers never run
  `sync_images`, so the notice could previously reach the very people it was
  written for only after they had already launched a session.

  The check itself still runs on the compute node (the launch form renders in
  the PUN, where a slow network call would delay every launch for everyone): a
  session caches the verdict, the form reads the cache with no network at all,
  and the banner clears itself once you update.

## [0.9.2] - 2026-07-13

### Added

- `CHANGELOG.md` (this file), with releases described in terms of what changes
  for users. The update notice says a new version exists; this says why you
  might want it.

## [0.9.1] - 2026-07-13

### Added

- `rstudio_slots` — inspect and tidy named session slots from a terminal: list
  them with size, last-used date and whether a session is running; `--rm SLOT`
  resets one (its next launch starts fresh); `--prune` clears slots idle 30+
  days. A slot with a running session is refused rather than pulled out from
  under it, and nothing here touches R libraries or the shared renv cache.
- `stage.sh` — deploy the current git branch as its own OnDemand app
  (`dev` → "RStudio Server (dev)", `feat/x` → "RStudio Server (feat/x)"), so any
  branch can be test-launched without touching the app other people use.
  `--list`, `--rm BRANCH`, and `--prune` (removes staged apps whose branch is
  gone) keep them from accumulating.

### Fixed

- The update notice read `RSTUDIO_APP_DIR`, a config key only a *full* install
  writes — so every install predating it would never have shown a notice at all.
  Both the job script and `sync-images` now fall back to the installer's default
  app directory.

## [0.9.0] - 2026-07-13

First tagged release. The app already existed; this is the point at which it
became something another person could install.

### Added

- **Portable installer.** An interview that discovers rather than assumes:
  large storage from the mount table, Slurm partitions from the partition ACLs
  (`AllowAccounts`/`DenyAccounts`/`AllowGroups` intersected with your accounts
  and groups), cluster id from Slurm, container runtime, and container bind
  paths. Nothing is hard-coded to one person, lab, or cluster. `?` at any
  prompt explains that question; `--dry-run` previews everything.
- **Lab-shared images.** A repository at `<lab storage>/users/shared/images/rstudio`
  is discovered automatically; whoever can write it is the maintainer, everyone
  else is a consumer and never syncs.
- **Update notices.** Deploys stamp a version; sessions and `sync_images`
  compare it against the repo and print a one-line notice when a newer release
  exists. Nothing ever self-updates.
- **Session slot on the card and in `squeue`**, and a session card that shows
  the credentials for the rare manual sign-in.
- **ERB test suite** (`test/run.sh`): renders every template against a fixture
  cluster and asserts on the output, supplying ruby from a container because the
  cluster has none. Runs in CI.
- **Terminal UX**: stepped, coloured installer; `sync_images` reports where it
  operates, image ages, and offers to pull when stale (`--watch` follows the job).

### Changed

- **Sessions no longer idle-suspend** (`session-timeout-minutes=0`). Each session
  owns a dedicated Slurm allocation, so suspending frees nothing — it only
  serialised multi-GB environments and raced renv on resume.
- **No `.RData` save/restore by default**, and sessions start in the work
  directory rather than a quota'd `$HOME`. Both are *defaults*: your own Global
  Options still win.
- **Configuration is no longer exported into your shell.** Sourcing the wrappers
  now defines functions and exports nothing, so no other R setup can see this
  app's variables.
- The auth window (`--auth-timeout-minutes`) now outlasts the longest possible
  job.

### Fixed

- **Security: the session password was the literal string `password`.** A HACK
  for idle logouts overwrote the generated random password — and with a
  cluster-reachable rserver port and usernames public in `squeue`, any user on
  the cluster could sign into a running session and execute code as its owner.
  The random password is kept; the Connect button submits it, and the session
  card shows it for manual sign-in.
- **`RSTUDIO_DATA_HOME` defeated session isolation.** It overrides
  `XDG_DATA_HOME` for RStudio specifically, so a user exporting it in their shell
  rc silently sent every session's state to one shared directory — concurrent
  sessions collided exactly as they did before slots existed. It is now pinned
  per-slot.
- **"Last used" reported when a slot was *created***, not when it was last used
  (a directory's mtime does not move when state is written deeper inside it).
- **renv cache split in two.** The wrappers left `XDG_CACHE_HOME` unset, so
  terminal R grew a second renv cache in `$HOME`, disjoint from the sessions'.
- **The torch CUDA hint never reached R through the wrappers** —
  `${var:+NAME=val}` in a command prefix is parsed as the command, not an
  assignment: invisible on CPU nodes, fatal on GPU ones.
- A maintainer's `umask` could make image metadata unreadable to consumers,
  silently degrading everyone else's launch form.
- Installer: storage discovery required *writable* directories; unwritable paths
  fail before the plan rather than mid-install; zsh users are told the wrappers
  are bash-only instead of having `.bashrc` edited pointlessly; an existing
  `r-wrappers.sh` source line is found across chained rc files.

[Unreleased]: https://github.com/mjz1/rstudio-ood/compare/v0.9.4...HEAD
[0.9.4]: https://github.com/mjz1/rstudio-ood/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/mjz1/rstudio-ood/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/mjz1/rstudio-ood/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/mjz1/rstudio-ood/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/mjz1/rstudio-ood/releases/tag/v0.9.0
