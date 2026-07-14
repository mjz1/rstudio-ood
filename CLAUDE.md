# CLAUDE.md

An Open OnDemand Batch Connect app that runs RStudio Server inside a Singularity
container on a compute node. See the [README](README.md) for architecture, and
`./install.sh --help` / `./sync-images.sh --help` for the tooling.

## This repo is not the app directory

Open OnDemand runs whatever sits in `~/ondemand/dev/<app>/` (the *sandbox app*
directory). This repo is the **source**; the app directory is a **deploy target**.

```
~/work/repos/rstudio-ood/       this repo -- edits here are INERT
        │
        │  ./install.sh --app-only
        ▼
~/ondemand/dev/rstudio_dev/     what OnDemand actually runs
~/ondemand/dev/rstudio_stage_*/ staged branches (./stage.sh), each its own app
```

- **Deploy:** `./install.sh --app-only` (app files only; leaves config, R
  libraries and caches alone). Full `./install.sh` re-runs the whole interview
  and rewrites `~/.config/rstudio_dev/config` -- that is for setting up, not for
  pushing an edit.
- **Stage:** `./stage.sh` deploys the CURRENT branch as its own OnDemand app
  (`dev` -> "RStudio Server (dev)", `feat/x` -> "RStudio Server (feat/x)"), so
  any branch can be test-launched without touching the app other people use.
  `./stage.sh --list` shows them, `--rm BRANCH` / `--prune` clean up (prune
  removes apps whose branch is gone). Staged apps share the one config and the
  same session slots -- do not run the SAME slot from two apps at once.
- This split exists because the repo *used to be* the sandbox directory: every
  edit, checkout and stash was instantly live. If you find yourself editing files
  under `~/ondemand/`, you are editing production.

## Branching and releases (binding, for agents and humans alike)

**master contains released code only, because master IS the distribution
channel**: the `curl | bash` install URL serves master, and the update notice
compares installs against `master/VERSION`. An unreleased commit on master is
an unreleased commit in every future user's install. Therefore:

- **All work happens on `dev`** (feature branches optional; merge them to dev).
  Never commit directly to master.
- **master moves only via `./release.sh X.Y.Z`**, which verifies the suite,
  merges dev, writes VERSION (VERSION always equals the latest tag -- never
  edit it by hand), tags, pushes, and re-syncs dev.
- **Deploy targets follow branches**: `./stage.sh` deploys the current branch
  (dev or a feature branch) as its own staging app; stable (`rstudio_dev`)
  deploys from master
  (`git switch master && ./install.sh --app-only && git switch dev`).
- **Versioning**: pre-announcement bake-in lives on `0.9.x` -- release
  liberally, they are free while the user base is one person. `v1.0.0` is the
  announcement to the lab itself. After that, bump when downstream installs
  should update (the notice fires on any VERSION difference).
- **Every user-visible change adds a `CHANGELOG.md` [Unreleased] entry in the
  same commit** (Added / Changed / Fixed / Removed). This is not bookkeeping:
  the update notice tells users a new version exists, and the changelog is the
  only place that tells them *why they should care*. `release.sh` refuses to
  release while [Unreleased] is empty, then rolls it into the version section,
  dates it, fixes the compare links, and copies it into the tag message.
  Internal-only churn (tests, refactors with no user-visible effect) does not
  need an entry.

## Ground truth about this environment

- **The portal is not this machine.** OnDemand renders the ERB templates inside
  the PUN, on the web node, and `ruby` is not installed anywhere on the cluster.
  That was treated as a hard limit for a long time -- it is not. **`test/run.sh`
  renders the templates and asserts on the output**, supplying ruby from a 40 MB
  container when the host has none (we already depend on a container runtime).
  Run it before every deploy.
  - It builds a fixture cluster in `$TMPDIR` (images, libraries, config) and
    reproduces OnDemand's binding: `context` for `script.sh.erb`, bare locals for
    `submit.yml.erb`. It then bash-parses the job script the template generates,
    *and* the rsession wrapper that script writes as a heredoc.
  - The suite must be **hermetic**. `ENV[key] || config[key] || default` means any
    exported `RSTUDIO_*` shadows the fixture, so the tests would silently read the
    developer's own cluster and pass for the wrong reasons. `erb_test.rb` scrubs
    `RSTUDIO_*`/`R_LIBS_*` from `ENV` before rendering, and `run.sh` reads
    `conf.sh` in a subshell so it cannot export anything. Do not undo either.
  - What it still cannot catch: OnDemand-specific binding differences and
    anything that needs real Slurm. **Test on a staged app** (`./stage.sh`),
    not the one your lab uses.
- The PUN does not reliably source your shell rc, so **environment variables do
  not reach the ERB templates**. Configuration lives in
  `~/.config/rstudio_dev/config`, written by `install.sh` and read by all four
  consumers (`form.yml.erb`, `script.sh.erb`, `sync-images.sh`, `r-wrappers.sh`).
  Environment still wins when set, for one-off overrides.
- **No cron.** `scrontab` is disabled cluster-wide and login-node `crontab` is
  blocked by PAM. Anything recurring must be run by hand or by a
  self-resubmitting Slurm job. Image syncing is done **by hand**
  (`sync-images.sh [--sync]`) -- a scheduled variant was tried and dropped.
- Login nodes must not run compute. `sync-images.sh` splits this deliberately:
  the digest check is three HTTP HEAD requests and runs anywhere; the ~2 GB pull
  plus squashfs conversion is submitted with `sbatch`. If `$SLURM_JOB_ID` is
  already set it runs inline instead.

## Nothing may be hard-coded to one user, lab, or cluster

This app is meant to be adopted by other people. Every path, partition and
cluster id is either asked for by `install.sh` or discovered from the machine it
runs on. Concretely, and each of these was a real bug:

- **Storage is discovered, not assumed.** The image directory used to default to
  a path inside the author's home, which for anyone else was either unreadable
  (reported as "does not exist" -- a permissions error wearing the wrong hat) or
  unwritable. `install.sh` now proposes large storage found on the machine
  (`~/work`, `$SCRATCH`, `/data1/*/users/$USER`) and asks.
- **Home directories are quota'd and shared.** The three directories that grow
  (images ~16-32 GB, R libraries, session state + renv cache) must not land on
  the home filesystem, and `install.sh` warns when they do -- including under
  `--yes`, the `curl | bash` path where nothing was asked. It compares **mount
  points**, not path prefixes: `~/work` is often a symlink onto large storage and
  is perfectly fine, and `stat -c %m` does not follow symlinks, so resolve first.
- **Partitions come from Slurm's ACLs.** `install.sh` reads each partition's
  `AllowAccounts` / `DenyAccounts` / `AllowGroups` and intersects them with the
  user's associations and unix groups. The old hard-coded default `cpu` is a
  partition this cluster *denies* to the accounts that actually use the app.
- **A partition is a GPU partition when EVERY node in it has a GPU.** Not when
  *some* node does -- GPU nodes belong to CPU partitions too (`cpushort` has 34
  among 235), so that test labels everything GPU. Not by name either; that is a
  convention, not a fact.
- **Container binds come from `RSTUDIO_BIND_PATHS`**, derived from the
  filesystems the chosen directories live on. A bind path missing on a compute
  node is skipped at session start, because singularity aborts on a bind source
  that does not exist.
- Every config key defaults to the value that used to be hard-coded, so an
  existing install keeps working untouched.
- **A lab-shared image repo is discovered, not configured**: the glob
  `/data1/*/users/shared/images/rstudio` (same family as the storage-root
  globs), adopted only when it holds at least one `rstudio-*.sif` -- an empty
  stub must not hand a new user an empty form. Writability decides
  maintainer/consumer as usual. The shahs3 shared repo lives there; the files
  are HARDLINKS of the originals in the maintainer's own tree, so migration
  cost nothing and deleting either path leaves the other intact.
- **conf.sh must never export.** It used to `export` every config key into the
  sourcing shell, spraying a dozen variables (including the generically named
  `R_LIBS_ROOT`) into the environment of everything the user runs -- other R
  setups included -- and causing the stale-env-shadows-new-config problem twice
  in one day. Values are plain shell variables now: visible to the wrappers
  (same shell), invisible to child processes. Consumers source the config file
  themselves; installer re-runs get continuity by seeding defaults FROM the
  file. Do not reintroduce the export.
- **One writer per config key.** install.sh is the only thing that writes
  `~/.config/rstudio_dev/config`. sync-images' `--image-dir` is deliberately a
  one-off (and says so): if sync could also rewrite the key, a casual
  experiment could silently repoint the OnDemand form.
- Terminal UI (colours, glyphs, step headers) lives in `ui.sh`, sourced by both
  install.sh and sync-images.sh, degrading to plain text when stderr is not a
  TTY / NO_COLOR / TERM=dumb, and to ASCII outside UTF-8 locales. Interactive
  prompts (installer questions, sync's confirm-to-pull) are additionally gated
  on `/dev/tty`, so scripts and sbatch jobs never see them.

## Bash gotchas that have bitten us here

- **`local IFS=','` is dynamically scoped.** A function that splits a list on
  commas leaks that IFS into *every function it calls*. `_enrich_queues` did
  this, and the `read -r total gpu` inside `_is_gpu_partition` then split on
  commas instead of whitespace -- silently labelling every GPU partition "CPU" in
  the launch form. Prefix the assignment to the command (`IFS=, read -r ...`)
  rather than declaring it `local`.
- **`stat -c %m` does not follow symlinks.** It reports `/home` for `~/work`
  even when that is a symlink onto `/data1`, which made the storage discovery
  reject the one good answer. `readlink -f` first.
- **`${var:+NAME=val} cmd` is not an assignment.** Bash decides what is an
  assignment BEFORE expansion, so text that materialises out of `${:+}` is
  parsed as the COMMAND ("NAME=val: No such file or directory"). The wrappers'
  `${cuda_env:+SINGULARITYENV_CUDA=...}` had this bug -- invisible on CPU nodes
  (empty expansion), fatal on every GPU node, meaning the torch-CUDA hint never
  worked through `salloc` + `R_` until 2026-07. Conditional env vars go through
  `env "${array[@]}"`.
- **`tr ' ' '─'` shreds multibyte glyphs.** tr is byte-wise; build rules by
  repetition. (ui.sh, shared by install.sh and sync-images.sh, does this
  correctly -- change it there, not in the callers.)
- **`pkill -f <pattern>` matches its own command line.** A cleanup like
  `pkill -f 'script -qec'` kills the shell running it when that string appears
  in its own argv.
- **This user's interactive shell often runs INSIDE a Slurm allocation**, so
  `SLURM_JOB_ID` is set in "ordinary" terminals. Anything gated on "am I in a
  Slurm job" as a proxy for "am I the batch job" will misfire for humans here
  -- gate on the precise thing instead (own job id, `--local` flag, or no TTY).
  This shipped as a bug once: sync-images' confirm prompt never appeared.
- **`/tmp` is node-local.** An sbatch job's output written to `/tmp/...` lands
  on the compute node and is unreadable from the login node; test logs go on
  shared storage (`~/work`).

## Singularity gotchas that have bitten us

- **The host environment leaks into the container.** This host exports
  `SSL_CERT_FILE=/etc/pki/…` and `SSL_CERT_DIR=/etc/pki/…` (RHEL paths) which do
  not exist inside the Ubuntu image, breaking OpenSSL TLS. Quarto reports
  `Failed to load platform certificates`, which points nowhere near the cause.
  Both `script.sh.erb` and `r-wrappers.sh` remap these to the container's own CA
  bundle. Do **not** reach for `--cleanenv` -- it also strips `SLURM_*` and
  `R_LIBS_USER`.
- The SIF is **read-only at runtime**, whatever the file permissions say.
  Anything the container needs to write must be bind-mounted from `$HOME` or
  `$TMPDIR`.
- `rserver` inside the image logs to syslog by default (rocker's setting), and
  there is no syslog socket in a container -- so startup failures produce **no
  output at all**, and the only symptom is `wait_until_port_used` timing out.
  `script.sh.erb` binds a `logging.conf` with `logger-type=stderr` so errors
  reach the job's `output.log`. Keep it.
- **GPU passthrough is `--nv`, gated on Slurm's GPU-allocation signal -- not a
  device probe.** `script.sh.erb` and `r-wrappers.sh` add `--nv` to `singularity
  exec` only when `CUDA_VISIBLE_DEVICES` / `SLURM_JOB_GPUS` is set (Slurm's gres
  plugin sets these only when a GPU was granted).
  - **Partition name is not a GPU signal.** GPU nodes here also belong to CPU
    partitions (`componc_cpu` etc.), so "am I on a gpu partition" is unreliable.
  - **`/dev/nvidia*` is not a GPU signal either -- this was measured, not
    assumed.** A CPU job that lands on a GPU-capable node *sees* `/dev/nvidia0..N`
    despite being granted no GPU (`CUDA_VISIBLE_DEVICES` unset). Probing the
    device files would enable `--nv` for a CPU session and let it grab a GPU
    allocated to another user -- a real multi-tenancy bug. The Slurm variables
    are what actually track the grant.
  `--nv` binds only the host driver (`libcuda.so`); the CUDA toolkit is not in
  the image. Frameworks (`torch`/`tensorflow`) bring their own and load it at
  runtime, which is why one image serves both CPU and GPU.
- **R torch needs a CUDA hint; the driver alone is not enough.** Unlike Python
  torch (whose pip wheel bundles CUDA), R torch's auto-installer picks CPU vs GPU
  by looking for a *system* CUDA toolkit -- which the image deliberately lacks --
  so it installs the CPU build even on a GPU node (`cuda_is_available()` FALSE
  despite `nvidia-smi` working). A GPU session therefore exports `CUDA=<version>`
  into R so the installer fetches the GPU build. The version is **derived, not
  hardcoded**: the highest torch-supported build (`RSTUDIO_TORCH_CUDA`, default
  `12.9 12.8 12.6`) that does not exceed the node's driver ceiling
  (`nvidia-smi`'s "CUDA Version"), read live per node. It is exported via the
  `rsession` wrapper (rserver strips the session env, so env vars set on the
  `singularity exec` line do not reach rsession -- same reason `R_LIBS_USER` is
  passed there). `libtorch` lands in the per-version R library, so it is
  per-R-minor and ~6 GB each.

## Concurrent sessions

Each OnDemand session is its own `rserver` on its own node, so server state is
already per-job. Concurrent sessions collided only on **shared `$HOME` RStudio
state**: `~/.local/share/rstudio` (`XDG_DATA_HOME/rstudio` -- session/workspace
state), the cache, and an abend-reset loop that rewrote *every* active session's
`session-persistent-state`. Fixed with **named slots**: `session_name` /
`new_session_name` form fields → a sanitised slot → **per-slot `XDG_DATA_HOME`
only** under `$RSTUDIO_WORK_DIR/.rstudio-sessions/<slot>/data`. The work dir is
chosen at install time and lives on large storage, NOT `$HOME` (which is small).

**`RSTUDIO_DATA_HOME` must be pinned per-slot, not just `XDG_DATA_HOME`.** It
overrides XDG_DATA_HOME *for RStudio specifically*, so a user who exports it in
their shell rc -- a common trick for keeping session state off a quota'd `$HOME`
-- silently defeats the entire slot mechanism: every session writes to that one
shared directory, concurrent sessions collide exactly as they did before slots
existed, and the abend-reset (which looks under the slot) becomes a no-op. This
was live on the developer's own account for the whole lifetime of the feature,
undetected, because everything *looked* right: `data/claude` and
`data/SeuratData` were correctly per-slot -- only RStudio's own state was not.
`script.sh.erb` now sets it explicitly in both the rserver env and the rsession
wrapper. The general lesson: an app-specific override of a standard variable is
a supply chain of one, and the user's rc is upstream of it.

**`XDG_CACHE_HOME` must stay shared** -- this was a bug fix. renv keeps its
library and cache under `R_user_dir("renv","cache")` == `$XDG_CACHE_HOME/R/renv`,
so a per-slot cache pointed `.libPaths()` at an empty per-slot renv root and
every installed package vanished. `XDG_CONFIG_HOME` is likewise shared
(`~/.config`) so preferences persist. Only RStudio's session state (under
`XDG_DATA_HOME/rstudio`) needed isolating. Side effect: packages that store data
under `XDG_DATA_HOME` (e.g. `SeuratData`) become per-slot.

**The wrappers align with the sessions' cache too.** When the host shell does
not export `XDG_CACHE_HOME`, `r-wrappers.sh` sets it to
`$RSTUDIO_WORK_DIR/.cache` inside the container -- otherwise terminal R quietly
grows a SECOND renv cache in quota'd `$HOME`, disjoint from every package the
sessions installed (the reference cache is 70 GB; that must never fork). An
exported value still wins, same precedence as everything else.

**The slot travels to the session card via conn_params.** `submit.yml.erb`
declares `session_slot`, `before.sh.erb` assigns it (third copy of the
sanitising -- all three must agree), and `view.html.erb` shows it guarded with
`defined?` so cards of sessions that predate the param still render.

Works with open-source RStudio Server (no Workbench) because the sessions are
separate `rserver` processes -- only the filesystem state had to be split. The
slot is one sanitised path segment (`[^A-Za-z0-9._-]`→`_`, leading dots stripped)
so it cannot escape the sessions root.

## Images vs libraries

**Images are a shared artifact. R package libraries are per-user.**

Packages are compiled against a specific R *minor* version and installed into a
directory you own, so `4.5_singularity` and `4.6_singularity` are not
interchangeable. Consequently:

- `script.sh.erb` **derives** `R_LIBS_USER` from the selected image rather than
  offering it as a separate form field. There used to be two independent selects,
  and the R 4.4 option pointed at a library directory that did not exist.
- **R ignores a missing `R_LIBS_USER` silently.** A wrong path is not an error,
  it is an invisible loss of every package you installed. Never fall back to
  another version's library; fail loudly instead.
- `form.yml.erb` offers only versions whose library directory exists, and
  `r-wrappers.sh` defaults to the newest R with a *populated* library -- not to
  `latest`, which tracks the newest image and could silently move you onto an R
  version whose library you have not built yet.
- One person can maintain the image directory for a whole lab
  (`RSTUDIO_SYNC_ROLE=maintainer`); everyone else is a `consumer` and
  `sync-images.sh --sync` refuses rather than failing on write permission inside
  a Slurm job.

## Images are rolling

`sync-images.sh` records the registry manifest digest of each `.sif` in a
`.digest` sidecar, so staleness is detected with HTTP HEAD requests rather than a
multi-GB download. The upstream repo (`mjz1/rstudio-img`) rebuilds its rolling
`4.3`–`4.6` tags monthly, so **an image can change under a stable filename**.

- The previous build is retained as `rstudio-<ver>.sif.prev` (a hardlink, so it
  costs nothing until the new image lands). Rollback is a rename.
- `images.json` records digest, R/RStudio/Quarto versions and pull time for every
  image, so you can reconstruct what an analysis ran under.
- What actually moves between rebuilds is *not* mostly R. One rebuild took
  RStudio Server from 2025.09 to 2026.06 in a single step. R's patch version is
  the least significant thing in the image.

## Known sharp edges

- **The session password must stay random.** For years `before.sh.erb`
  overwrote the generated password with the literal string `password` (a HACK
  for idle logouts), which let any cluster user sign into a running session --
  the rserver port is reachable from other nodes, usernames are public in
  squeue, and the auth window is 6000 minutes. `password` is one of OnDemand's
  DEFAULT connection params (with host and port), so the random value reaches
  view.html.erb's Connect button with no extra plumbing -- the hack never bought
  anything. If idle logouts recur, raise `--auth-timeout-minutes`, never this.
- `script.sh.erb` passes `--database-config-file` to work around an image bug
  fixed upstream in `rstudio-img` v1.1.1. It is now redundant for current images
  but still protects older ones. If you want to confirm the upstream fix stands
  on its own, drop the flag for one launch -- otherwise a regression could hide
  behind the workaround indefinitely.
- `~/.alias` is tracked in a separate bare dotfiles repo (`$HOME/.cfg`), not this
  one. It sources `r-wrappers.sh` from the **deployed** app
  (`~/ondemand/dev/rstudio_dev/r-wrappers.sh`), so the shell wrappers match what
  OnDemand runs rather than an in-progress edit.
