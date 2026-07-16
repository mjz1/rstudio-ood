# Changelog

Notable changes, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

**`0.9.x` is pre-release**: the app is public but not yet announced to users, so
breaking changes are still cheap. `1.0.0` will mark the release to the lab.

Update an existing install to the latest release with:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/main/install.sh | bash -s -- --app-only
```

## [Unreleased]

### Added

- **AI agent access (MCP), opt-in per session.** A new launch-form select —
  Off / Read-only / Read + execute — lets a coding agent running in the
  session's Terminal (Claude Code, Copilot CLI, any MCP client) see the live
  R session via the `mcptools` + `btw` R packages: list objects, describe
  in-memory data frames, look up package docs, and — in execute mode, with
  the agent asking approval on every call — run R code in the session itself
  and drive the R-package-development tools (`R CMD check`, tests, coverage,
  roxygen docs, `load_all`), so an agent can develop notebook code
  chunk-by-chunk against live state instead of re-rendering to find each bug,
  or iterate on a package in place. Enabled sessions auto-register at
  startup (after renv activation, so project libraries work); one-time
  project setup is the new `rstudio_mcp_init` wrapper. Off is the default and
  changes nothing; no network ports are involved (node-local sockets only),
  and read-only sessions never expose an execute tool. (#1)

- **MCP sessions are guarded against the prompt deadlock.** Agent-submitted
  code that waits for console or UI input would block the single-threaded R
  session's event loop and wedge it permanently — every later tool call timing
  out, recoverable only by a human at the console. Two layers now prevent it:
  execute-mode sessions disarm the prompts that fire from inside package code
  (`devtools`/`renv` install prompts, `askYesNo`), and the MCP server screens
  submitted code before it reaches the session, refusing `readline`, `scan`,
  `menu`, `browser`, `readLines()` on stdin, `file.choose`, `edit`, `locator`
  and the interactive `rstudioapi` dialogs with an explanatory error. The
  screen parses rather than greps, so mentions in comments and strings pass;
  it wraps the tool itself, so it protects every client of this server rather
  than one vendor's. A `.mcp.json` written before the guard existed is
  detected by `rstudio_mcp_init`, which prints the replacement entry. (#2)

- **A `session_status` tool that works even when the session is wedged.** A
  second MCP server (`r-session-status`, written into the same `.mcp.json`)
  never connects to the session: it observes the rsession process via
  `/proc` from its own process — the session's CPU, its children's CPU
  (`system()` running an external tool looks idle from the session itself),
  whether a `run_r` call is still unanswered, and — via
  `/proc/<pid>/syscall` — what the session is blocked in, and reports idle /
  busy / busy-subprocess / waiting-timer / waiting-io / waiting / dead with
  the evidence. Only a pure sleep (`nanosleep`) is confidently self-clearing
  (`waiting-timer`, "no action"), and disk I/O is a transfer (`waiting-io`);
  a `poll`/`select` with a timeout — which looks identical whether it is a
  `Sys.sleep` or an event loop wedged forever — an indefinite wait, and a
  blocking read all fall to bare `waiting`, where the advice names the
  syscall and hands the judgement to the agent (which knows whether its code
  does I/O or could have prompted). Agents call it after a timeout instead of
  probing the session, which corrupts recovery. (#2)

- **Read-only sessions are read-only twice over.** btw's `BTW_RUN_R_ENABLED`
  only gates its *default* tool set — a tool list that explicitly names
  `run_r` (as a config override could) is served with the variable unset. A
  read session now filters the execute tools out of the served list whatever
  the override says *and* exports `BTW_RUN_R_ENABLED=false` explicitly. A
  tool list that is set-but-empty falls back to the read default instead of
  btw's entire default set (which includes file-write and web tools). (#2)

- Docs: why `install.packages()` can claim a package "is not available" that
  exists on CRAN — every image's mirror is a dated Posit Package Manager
  snapshot, permanently so for older R versions (rocker policy). The new
  section in `docs/images.md` covers the one-off `repos =` override, a
  two-repo "newest compatible, else era version" default, and renv for
  projects that must stay stable for years; the README's Known issues points
  at it.
- README: the two `ERROR` lines every session logs (the Posit Assistant's
  Node backend warning about SQLite, and RStudio's memory display reading an
  already-exited process) are documented as benign. They look alarming, they
  are not, and they cannot be filtered — RStudio emits them at `ERROR`, above
  any threshold the app can set — but they now land in a per-session log file
  instead of the R console (see Fixed).

### Changed

- Deploys now copy only the app files (OnDemand templates plus
  `sync-images.sh`, `r-wrappers.sh`, `conf.sh`, `ui.sh`) instead of the whole
  repo. Repo tooling — installer, tests, docs, release scripts — no longer
  lands in the app directory, and the next deploy removes the copies that
  earlier deploys left there. Nothing you use moves: `~/.alias` keeps sourcing
  `r-wrappers.sh` from the same place, and `sync-images.sh` still runs from
  the app directory. If you kept a habit of running the deployed `install.sh`,
  run it from a checkout (or `curl | bash`) instead.

### Fixed

- RStudio's internal log records no longer print into the R console. The
  session process forwards its own stderr to the console, and the app's
  logging override — needed so *server* startup failures reach `output.log` —
  also pointed the session's logger at stderr, so benign records sprayed into
  every console, timestamps and all: the memory monitor's `/proc` read races
  (`Proc stat file … missing value`, a process exiting between enumeration and
  read) and the Posit Assistant backend's stderr (the SQLite
  `ExperimentalWarning`, re-logged at `ERROR`). `logging.conf` now defaults
  *every* logger to a file under `logs/` in the session's OnDemand output
  directory, with only `rserver` on stderr — so launch failures still reach
  `output.log`, while every session-side record (including Assistant
  sub-loggers that a per-`rsession` rule slipped past) stays out of the
  console and next to `output.log` for debugging.

### Removed

- `form.yml.bak`, the retired hard-coded launch form, is gone from the repo
  (and from deployed app directories). It lives on in git history.

## [0.9.7] - 2026-07-14

### Changed

- The "See what changed" link in the launch form opens in a new tab, so
  reading the changelog no longer navigates away from a half-filled form.

## [0.9.6] - 2026-07-13

### Changed

- The default branch is now `main`. This matters more here than in most repos:
  the branch name is part of the install URL and the update-notice check, and
  `raw.githubusercontent.com` does not redirect renamed branches. Installs
  updated from this release onward use the new URLs; the old `master` raw URLs
  stop resolving, so update any pinned copies of the one-liner.

## [0.9.5] - 2026-07-13

### Changed

- The update notice got a face-lift on both surfaces: the launch form renders
  the update command as a copy-paste-able code block (with the changelog link
  alongside), and the R console prints a tidy ruled banner — versions, a
  clickable changelog link, and the command — instead of one run-on line.

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

[Unreleased]: https://github.com/mjz1/rstudio-ood/compare/v0.9.7...HEAD
[0.9.7]: https://github.com/mjz1/rstudio-ood/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/mjz1/rstudio-ood/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/mjz1/rstudio-ood/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/mjz1/rstudio-ood/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/mjz1/rstudio-ood/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/mjz1/rstudio-ood/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/mjz1/rstudio-ood/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/mjz1/rstudio-ood/releases/tag/v0.9.0
