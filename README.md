# RStudio Server (Open OnDemand)

An Open OnDemand app that runs RStudio Server inside a Singularity container on a
Slurm compute node. Multiple named sessions, GPU support, and one shared set of
container images that a whole lab can read.

Nothing is hard-coded to one person, lab or cluster: the installer asks where
things go and discovers the rest from the machine it runs on.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/master/install.sh | bash
```

That runs an interview (reading your answers from the terminal even though the
script arrives over a pipe). Answer `?` at any prompt for a full explanation.
To preview everything without changing anything, add `--dry-run`:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/master/install.sh | bash -s -- --dry-run
```

It asks you **three questions that matter** and works the rest out for itself:

- **Where do the big directories go?** Images, R libraries, session state.
  It proposes large storage it found and **warns you off your home directory**,
  which is small, quota'd, and shared.
- **Do you maintain the images, or use someone else's?** Point it at a
  colleague's image directory and you never sync anything.
- **Which rc file** gets the shell wrappers (`R_`, `Rscript_`, `bash_`).

Everything else is discovered: your Slurm partitions (from the ACLs — only
queues your account may actually submit to, labelled with GPU type and time
limit), the cluster id, the container runtime, and the filesystems that need
binding into the container.

Then reload your shell and pull the images (skip this if you use someone
else's — theirs are already there):

```bash
source ~/.bashrc        # or whatever rc file you chose
sync_images --sync      # submits a Slurm job; ~2 GB per R version
```

and open **Interactive Apps → RStudio Server** in OnDemand.

See [Install in detail](#install-in-detail) for every option, what it touches,
how to share images across a lab, and how to uninstall.

## How the pieces fit

The container images are built and published by
[mjz1/rstudio-img](https://github.com/mjz1/rstudio-img) to Docker Hub
(`zatzmanm/rstudio`) and GHCR (`ghcr.io/mjz1/rstudio-img`). Nothing in this app
builds images; it only consumes them.

```
  rstudio-img (GitHub Actions)         registry              this cluster
  ────────────────────────────         ────────              ────────────
  monthly rebuild + on release  ──►  :4.3 :4.4               sync-images.sh
                                     :4.5 :4.6  ──digest──►  rstudio-<ver>.sif
                                     :latest                 rstudio-<ver>.sif.digest
                                                             images.json
                                                                   │
                                                        form.yml.erb reads it
                                                                   │
                                                        script.sh.erb runs it
```

**The registry is the source of truth.** Each local `.sif` carries a `.digest`
sidecar recording the registry manifest digest it was pulled from, so
`sync-images.sh` can detect drift with three HTTP HEAD requests instead of a
4 GB download.

### The three directories, and why they are not in your home

Everything this app stores on disk lands in one of three places. All three grow,
and `install.sh` asks you where each one goes — because an HPC home directory is
small, quota'd and shared, and filling it breaks your logins, not just RStudio.

| Directory | Config key | Holds | Grows to | Shareable? |
|---|---|---|---|---|
| Images | `RSTUDIO_IMAGE_DIR` | `rstudio-<ver>.sif` + digests + `images.json` | ~2 GB per R version, doubled while the previous build is kept — **16–32 GB** for four | **Yes** — one directory can serve a whole lab |
| R libraries | `R_LIBS_ROOT` | one `<ver>_singularity` directory per R minor version | unbounded; `libtorch` alone is ~6 GB **per R version** | **No** |
| Work dir | `RSTUDIO_WORK_DIR` | `.rstudio-sessions/<slot>` (session state), `.cache` (renv library + cache, container pull cache) | tens of GB | **No** |

The images are the only thing that *can* be shared, and they are identical for
everyone — so one person maintains a directory and everyone else reads it
([how](#sharing-images-across-a-lab)). The R libraries cannot be shared:
packages are compiled against a specific R minor version and installed into a
directory you own.

`install.sh` warns if any of the three lands on your home filesystem — including
under `--yes`, which is the run where nobody was asked anything. It decides by
comparing mount points, not by matching path prefixes, so a `~/work` symlink onto
large storage is correctly recognised as fine.

## Using it

### Signing in (there is no password field, on purpose)

The launch form has no password box because you do not choose one. Each session
gets a **random 16-character password**, generated at job start and persisted by
OnDemand in that session's `connection.yml` (mode `0600` — only you can read it).
The **Connect to RStudio Server** button on your *My Interactive Sessions* card
submits it for you.

**If RStudio ever signs you out**, click **Connect to RStudio Server** again. The
button performs a full sign-in on every click, so it just puts you back in — you
never have to remember anything. If RStudio's own sign-in page appears and the
button will not clear it, expand *"Signed out of RStudio? Click here."* on the
session card, which shows the username and password for that session.

In practice this is rare: the Connect form sets `staySignedIn`, and
`--auth-timeout-minutes` is 6000 (100 hours) — both longer than the 7-day job
ceiling — so the usual way to see a sign-in page is to explicitly sign out.
(The password was not always random; see [Known issues](#known-issues) if you
inherit an older copy of this app.)

### Multiple concurrent sessions

You can run several RStudio sessions at once — one per project, say — and switch
between them instantly instead of reloading. Each session is an independent
`rserver` on its own node; sessions are isolated by a **named slot**:

- The launch form has a **Session** dropdown listing your existing slots (newest
  first, with a "last used" hint) — pick one to resume its state — plus a **New
  session name** field to start a fresh named slot.
- Each slot gets its own `XDG_DATA_HOME` under
  `$RSTUDIO_WORK_DIR/.rstudio-sessions/<slot>/data`, so concurrent sessions never
  touch each other's open documents, console history, or session registry. Slots
  live in the work directory you picked at install time — on large storage,
  **not your space-limited `$HOME`**.
- **The cache and preferences stay shared.** `XDG_CACHE_HOME`
  (`$RSTUDIO_WORK_DIR/.cache`) is deliberately *not* per-slot — renv keeps its
  package library there (`$XDG_CACHE_HOME/R/renv`), so isolating it would move
  every project's library out from under `.libPaths()`. `XDG_CONFIG_HOME`
  (`~/.config`) is shared too, so themes/keybindings/settings and your R package
  library are consistent across sessions.
- Slot state **persists**, so a slot resumes where you left it. The Slurm job is
  named `rstudio-<slot>`, and the session card says which slot it is running.
- **Note:** packages that cache *data* under `XDG_DATA_HOME` (e.g. `SeuratData`)
  become per-slot, so you'd install those datasets once per slot.

Reconnecting to a session that is still **running** is done from OnDemand's *My
Interactive Sessions* page (as always); the form's Session dropdown is for
choosing which slot to **launch or resume**.

Caveats:
- **Do not open the same project in two slots at once** — RStudio locks a
  project's `.Rproj.user`/`.RData`; one project per slot is the safe pattern
  (and the point).
- Installing packages from two sessions simultaneously can occasionally race on
  the shared library directory.
- Each session is a separate Slurm allocation, so N sessions use N jobs' worth of
  cores/memory/GPU against your limits.

### GPU sessions

To use a GPU:

1. Pick a **GPU-capable partition** in the Queue dropdown.
2. Set **Number of GPUs** > 0.
3. In the session, install a framework that uses the GPU — e.g. `torch`:
   ```r
   install.packages("torch"); library(torch)
   cuda_is_available()   # TRUE on a GPU node
   ```

**R torch and the CUDA build.** The image ships no CUDA toolkit (by design — see
below), and R torch's auto-installer decides CPU vs GPU by looking for a *system*
CUDA toolkit. Left alone it would install the **CPU** build even on a GPU node.
So a GPU session exports `CUDA=<version>` into R, and torch's installer fetches
the matching GPU `libtorch` instead (only the driver is needed at runtime; the
build bundles the toolkit). The version is **not hardcoded** — it is the highest
torch-supported build that does not exceed the node's driver ceiling
(`nvidia-smi`'s "CUDA Version"), chosen live per node, so it adapts to per-node
drivers and future upgrades. Override the supported list with `RSTUDIO_TORCH_CUDA`
(space-separated, highest first) if torch adds or drops a `cuXXX` build.

`libtorch` installs into your per-version R library
(`R_LIBS_ROOT/<ver>_singularity/torch/lib/`, ~6 GB extracted), so it persists
across sessions but is **per R minor version** — install it again under each R
you use with a GPU. If you already installed the CPU build, force a one-time
re-download: `torch::install_torch(reinstall = TRUE)` then restart R.

How it works, and why it is built this way:

- **The Queue dropdown is populated from `RSTUDIO_QUEUES`**, which `install.sh`
  *discovers* rather than asking you to type: it reads each partition's
  `AllowAccounts` / `DenyAccounts` / `AllowGroups` and keeps the ones your Slurm
  associations and unix groups actually permit. GPU partitions are site- and
  account-specific — on the reference cluster the shared `gpu` partition
  *denies* most lab accounts while lab-specific `*_gpu_*` partitions allow them
  — so a hard-coded list is wrong for everyone but its author.
- **Each option is labelled with its GPU type and time limit**, so you know what
  you are picking — e.g. `componc_gpu_int — GPU H100/H200 · <=1d · interactive`.
  A partition counts as GPU when **every** node in it offers a GPU — not when
  *some* node does, which is true of CPU partitions too (GPU nodes sit in both)
  and would label everything "GPU"; and not from its name, which is a naming
  convention rather than a fact. Labels are generated from Slurm at install
  time and stored in `RSTUDIO_QUEUES` as `partition|label` entries; the form
  displays the label and submits the bare partition. They go stale only if a
  partition's limits change — re-run `install.sh` to refresh.
- **`submit.yml.erb` adds `--gres=gpu:N`** only when GPUs > 0.
- **`--nv` is decided at session start, on the compute node**, from Slurm's
  GPU-allocation variables (`CUDA_VISIBLE_DEVICES` / `SLURM_JOB_GPUS`) — *not*
  the partition name, and *not* the presence of `/dev/nvidia*`. Both are
  unreliable: GPU nodes also sit in CPU partitions, and a CPU job that lands on a
  GPU node still *sees* `/dev/nvidia*` while being granted no GPU. Only the Slurm
  variables track the actual grant, so a GPUs = 0 session never gets `--nv` even
  on GPU hardware — which also stops it from grabbing a GPU allocated to someone
  else. The `output.log` records which path was taken.
- **The image ships no CUDA toolkit.** `--nv` binds only the host driver
  (`libcuda.so`); `torch`/`tensorflow` download a CUDA-enabled backend into the
  package library and load it at runtime. This is why a single image serves both
  CPU and GPU sessions with no `-cuda` variant. Compiling a package with `nvcc`
  against *system* CUDA is a separate, future case (upstream issue
  [rstudio-img#14](https://github.com/mjz1/rstudio-img/issues/14)).

The same probe is in `r-wrappers.sh`, so `R_`/`Rscript_`/`bash_` also get the GPU
when run inside a GPU allocation (e.g. `salloc -p <gpu_partition> --gres=gpu:1`).

### Shell wrappers

`r-wrappers.sh` provides `R_`, `Rscript_`, `bash_`, and `sync_images` for using
the same images outside OnDemand. The installer adds the `source` line to your
rc file (or tells you it is already there — it follows chains like
`.bashrc → .alias`); to do it by hand:

```bash
source "$HOME/ondemand/dev/rstudio_dev/r-wrappers.sh"
```

```bash
R_                       # newest R with a populated package library
R_ 4.5                   # a specific R minor
Rscript_ analysis.R      # arguments are forwarded
Rscript_ -v 4.5 foo.R    # pin the version
bash_ -v 4.3             # shell in the container
sync_images              # check the images (see below)
```

`R_`/`Rscript_`/`bash_` default to the newest R that has **both** an image and a
non-empty package library — deliberately not `latest`, which tracks the newest
*image*. Pulling a new major R therefore cannot silently strip the packages out
from under an existing script. A missing library is a hard error, never a
fallback to a different R's library.

The wrappers keep the renv cache aligned with sessions: when your shell does not
export `XDG_CACHE_HOME`, they set it to `$RSTUDIO_WORK_DIR/.cache` inside the
container, so terminal R and OnDemand R share one package cache instead of
quietly growing a second one in `$HOME`. An exported value still wins.

## Keeping images current

`sync_images` (the wrapper) forwards to `sync-images.sh` in the app directory —
the script is not on `PATH`.

```bash
sync_images                  # check; on a terminal, offers to pull if stale
sync_images --sync           # pull whatever is stale (submits an sbatch job)
sync_images --sync 4.6       # restrict to specific versions
sync_images --sync --local   # pull inline, when already inside an allocation
sync_images --watch          # follow the running/submitted sync job's log
sync_images --image-dir P    # one-off target for THIS run (config unchanged)
sync_images --manifest       # rebuild images.json from what is on disk
```

Every run opens by saying **where it operates** — the image directory, your role
(maintainer/consumer), the registry — because a sync tool should answer "where
does this pull to?" before it's asked. (Answer: `RSTUDIO_IMAGE_DIR` from your
config, never the current directory. `--image-dir` redirects one run for
experiments; *moving* the images is `install.sh`'s job.) The status table shows
each image's R/RStudio versions and how long ago it was pulled:

```
sync-images · /data1/lab/images/rstudio
  role: maintainer (owner: you) · registry: ghcr.io/mjz1/rstudio-img
    R     STATUS      DETAIL
  ✓ 4.5   up to date  R 4.5.3 · RStudio 2026.06.0+242 · pulled 2d ago
  ! 4.6   STALE       tag moved 9f2c41… -> f24a5d… · pulled 34d ago

  Pull 1 image(s) now (sbatch -> cpushort)? [Y/n]:
```

That closing prompt appears only on a terminal, only for a maintainer with
stale images — scripts, consumers, and the sbatch job itself keep the
check-only behaviour. If a sync job is already queued or running, every
invocation says so (with its log path) instead of letting you submit a
duplicate, and `--watch` attaches to it: state changes, live log, and a fresh
check when it finishes. Ctrl-C detaches without harming the job.

The check is three HTTP HEAD requests and belongs anywhere; the pull is ~2 GB
plus a squashfs build per image, so it goes to Slurm rather than a login node.
Inside an allocation (`$SLURM_JOB_ID` set) it runs inline on that node instead,
and the prompt says so.

There is no automation on purpose: the reference cluster has no cron
(`scrontab` disabled, login-node `crontab` blocked by PAM), and a self-
resubmitting job was tried and dropped. `rstudio-img` rebuilds its rolling tags
on the 1st of each month, so running `sync_images` some time after that is
enough — it will tell you what moved and offer the pull.

### Rolling images, and how to roll back

Images roll in place: `rstudio-4.5.sif` is overwritten when the registry's `4.5`
tag moves. The outgoing build is retained as `rstudio-4.5.sif.prev` (created as
a hardlink, so it costs no extra disk until the new image lands). To roll back:

```bash
cd "$RSTUDIO_IMAGE_DIR"
mv rstudio-4.5.sif.prev rstudio-4.5.sif
mv rstudio-4.5.sif.prev.digest rstudio-4.5.sif.digest
sync_images --manifest
```

`images.json` records the digest, R, RStudio and Quarto versions, and pull time
of every image, so you can always reconstruct what a given analysis ran under.

**What actually moves between rebuilds.** R's patch version is the *least*
significant thing here — the package ABI is stable within a minor version, so
your `4.5_singularity` library keeps working across 4.5.1 → 4.5.2. What moves
more: the Dockerfile upgrades RStudio Server to the latest stable Posit release
on every build (one rebuild took it from 2025.09.2 to 2026.06.0), and the
rocker base pins CRAN to a *dated* snapshot whose date advances when rocker
rebuilds, shifting every package version in the image's site library. Your
personal library shadows the site library, which insulates you from most of that.

## Install in detail

```bash
git clone https://github.com/mjz1/rstudio-ood.git
cd rstudio-ood
./install.sh --dry-run   # print the plan, change nothing
./install.sh             # the interview
./install.sh --yes       # accept every discovered default, ask nothing
./install.sh --help      # every option
```

The `curl | bash` one-liner and a checkout run the same script — the one-liner
just fetches the repo into a temp directory first.

### Requirements

- **Singularity or Apptainer** on the login and compute nodes (the installer
  detects which and records it).
- **OnDemand app development ("sandbox apps") enabled for your account.** The
  app installs into `~/ondemand/dev/`, which the portal only reads when your
  site has turned that on. The switch lives on the web node, so the installer
  cannot check it — if the app never appears under Interactive Apps, this is
  the first thing to ask your OnDemand admins about.
- **bash**, for the shell wrappers (`R_`, `Rscript_`, `bash_` are bash
  functions). If your login shell is zsh the installer says so and skips the
  rc-file step rather than breaking your startup; the OnDemand app itself does
  not care what your shell is.
- `python3` (any 3.6+) and standard GNU userland — true of effectively every
  Linux cluster.

### What it asks you

1. **A large-storage root.** It proposes one it found (`~/work`, `$SCRATCH`,
   `/data1/*/users/$USER`, …), skipping anything on your home filesystem or
   that you cannot write to. The three directories default underneath it, and
   each can be overridden separately. It shows free space for each, and pushes
   back if your answer is on the home filesystem.
2. **Whether you maintain images or use someone else's.** If the image directory
   you name is not writable by you, that answer is made for you — you are a
   *consumer*, and `sync_images --sync` will decline rather than fail.
3. **Whether to share your images** with your unix group (`chmod -R g+rX`). If
   the parent directories block group traversal, it names the offending
   directories instead of leaving you with a `chmod` that appears to have
   worked but didn't.
4. **Cluster and partitions.** The OnDemand cluster id defaults to Slurm's own
   `ClusterName`. The queue list defaults to *every partition your account may
   submit to*, each labelled with its GPU type and wall-clock limit.
5. **Which rc file** gets the `source .../r-wrappers.sh` line (`none` to skip).
   If the wrappers are already sourced somewhere — including one hop away, as
   in `.bashrc → .alias` — it says so and touches nothing. Under `--yes` it
   defaults to `~/.bashrc` for bash users and skips for other shells.

Answer `?` at any prompt for the full explanation of that question.

### Trying it safely

`--dry-run` previews everything and changes nothing. To go further and run it
*for real* without disturbing an existing setup, redirect the config and every
path it writes into a scratch directory:

```bash
T=$(mktemp -d)
RSTUDIO_DEV_CONFIG=$T/config ./install.sh \
    --storage-root  $T/storage \
    --app-dir       $T/app \
    --shell-init    none        # don't touch any rc file
```

That exercises the whole thing — discovery, the interview, the config file, the
deployed app — against `$T`, leaving your real config, OnDemand app and rc file
alone. `rm -rf $T` when you're done.

### What it touches

| Path | What |
|---|---|
| `~/.config/rstudio_dev/config` | every setting; **delete this to uninstall** |
| `~/ondemand/dev/rstudio_dev/` | the OnDemand app (copied, or symlinked with `--link`) |
| `$R_LIBS_ROOT/<ver>_singularity/` | one empty library per R version |
| `$RSTUDIO_WORK_DIR/{.rstudio-sessions,.cache}/` | session state and caches |
| `$RSTUDIO_IMAGE_DIR/` | created only if you are the maintainer |
| your rc file | one `source` line, only if not already there |

To uninstall: delete the config file and the app directory, and remove that one
`source` line. Your images, libraries and session state are just directories —
delete them if you want the disk back.

**What it deliberately does not do:** pull the images (that is a Slurm job — run
`sync_images --sync` afterwards) or populate your R libraries (they start
empty — install packages from inside RStudio, or `Rscript_ -e
'install.packages("data.table")'`). An R version with no library directory is
simply not offered by the form; that is deliberate, since R ignores a missing
`R_LIBS_USER` silently and every installed package would appear to vanish.

### Sharing images across a lab

One person maintains the image directory; everyone else points at it and never
writes to it.

```bash
# maintainer, once
./install.sh --image-dir /data1/lab/shared/rstudio --sync --share-images
sync_images --sync

# everyone else
./install.sh --image-dir /data1/lab/shared/rstudio --no-sync
```

Group read is not enough on its own: every parent directory of the image
directory also needs `g+x`, or your labmates can see the path and still not open
anything in it. `--share-images` opens the directory *and everything already in
it* (`chmod -R g+rX`), then checks the whole parent chain and names any
directory that still blocks group traversal.

The maintainer's umask cannot break consumers either: `sync-images.sh` sets the
mode of every `.sif`, `.digest`, `.info` and `images.json` explicitly, so a
maintainer with `umask 077` still publishes group-readable metadata.

### Another cluster, different partitions

Nothing needs editing. `install.sh` reads `AllowAccounts` / `DenyAccounts` /
`AllowGroups` off each partition and intersects them with your Slurm
associations and unix groups, so the Queue dropdown offers what you can actually
use and nothing else. (This is not cosmetic: on the reference cluster the shared
`cpu` partition *denies* most lab accounts, so a hard-coded default of `cpu`
produced jobs that were rejected at submit time.)

The container binds come from `RSTUDIO_BIND_PATHS`, derived at install time from
the filesystems your chosen directories actually live on, plus Slurm/munge. A
bind path that does not exist on a compute node is skipped at session start
rather than aborting the launch — so a site with no `/data1` does not inherit
ours.

### Configuration

`install.sh` writes `~/.config/rstudio_dev/config`, which is read by the
OnDemand form (`form.yml.erb`), the job script (`script.sh.erb`),
`sync-images.sh`, and `r-wrappers.sh`.

It is a file rather than a set of environment variables because OnDemand renders
the ERB templates inside the PUN, which does not reliably source your shell rc.
Environment variables still take precedence when they are set, so one-off
overrides work:

```bash
RSTUDIO_IMAGE_DIR=/tmp/testimages sync_images
```

| Key | Meaning | Scope |
|---|---|---|
| `RSTUDIO_IMAGE_DIR` | where the `.sif` images live | shared, read-only is fine |
| `R_LIBS_ROOT` | root of your R package libraries | **per-user** |
| `RSTUDIO_WORK_DIR` | session slots (`.rstudio-sessions/`) and caches (`.cache/`, incl. the renv library) | **per-user** |
| `RSTUDIO_BIND_PATHS` | comma-separated host paths bound into the container beyond `$HOME`; missing ones are skipped at session start | site |
| `RSTUDIO_SYNC_ROLE` | `maintainer` (may pull images) or `consumer` (read-only; `--sync` refuses) | per-user |
| `RSTUDIO_VERSIONS` | R minor versions to track when syncing | per-user |
| `RSTUDIO_SINGULARITY` | container runtime (`singularity` or `apptainer`) | site |
| `RSTUDIO_CLUSTER` | OnDemand cluster id (`/etc/ood/config/clusters.d` **on the web node**) | site |
| `RSTUDIO_QUEUE` | default Slurm partition, pre-selected in the dropdown | site |
| `RSTUDIO_QUEUES` | comma-separated partitions in the Queue dropdown, incl. GPU ones; each entry is `partition` or `partition\|label` (install.sh auto-labels with GPU type + time limit); falls back to `RSTUDIO_QUEUE` if unset | site |
| `RSTUDIO_SYNC_PARTITION` | partition `sync-images.sh` submits pulls to | site |
| `RSTUDIO_TORCH_CUDA` | space-separated R-torch CUDA builds, highest first (default `12.9 12.8 12.6`); the session picks the highest that fits the node driver | site |

Every key has a default that reproduces the previous hard-coded behaviour, so a
config file written before these keys existed keeps working untouched.

`RSTUDIO_STATE_DIR` is read from the environment only and defaults to the
current slot's own state directory
(`$RSTUDIO_WORK_DIR/.rstudio-sessions/<slot>/data/rstudio`). It exists only to
scope the "session did not exit cleanly" reset to one slot; it used to point at
a shared directory, which made launching one session clear every other running
session's abend flag.

## Developing and deploying it

**This repo is not the app directory.** Open OnDemand runs whatever sits in
`~/ondemand/dev/<app>/`; this repo is the source, and installing is a copy.
This separation exists because the repo *used to be* the sandbox directory, so
every edit, branch switch and stash was instantly live. If you find yourself
editing files under `~/ondemand/`, you are editing production — `install.sh`
warns if you run it from there.

```
~/work/repos/rstudio-ood/       the checkout -- edits here are INERT
        │
        │  ./install.sh --app-only
        ▼
~/ondemand/dev/rstudio_dev/     what OnDemand runs (you, and your lab)
~/ondemand/dev/rstudio_next/    staging copy, its own entry in the UI
```

| Command | Use |
|---|---|
| `./install.sh` | first-time setup: the interview, config, directories, shell wrappers |
| `./install.sh --app-only` | routine deploy: push your edits live, touch nothing else |
| `./install.sh --app-only --app-dir ~/ondemand/dev/rstudio_next --app-name "RStudio Server (next)"` | deploy a staging app |

`--app-only` deliberately skips the interview: redeploying an edit must not be
able to change your storage or partitions behind your back. The staging copy
appears as its own entry in OnDemand, giving you somewhere to click Launch that
isn't the app other people are using.

### Testing the ERB templates

The templates are the riskiest files in the app: OnDemand renders them inside the
PUN, and a mistake in them is not a stack trace but a session that will not start.
Run the suite before you deploy:

```bash
./test/run.sh
```

```
form.yml.erb
  ok   DROPS R 4.4: it has an image but no library (a silent R_LIBS_USER loss)
  ok   a "·" inside a label does not split the entry (commas are the delimiter)
template/script.sh.erb
  ok   R_LIBS_USER is derived from the SELECTED image (4.5 image -> 4.5 library)
  ok   a traversal in the session name is sanitised to one path segment
  ok   GPU: --nv is gated on Slurm granting a GPU, never on /dev/nvidia*
view.html.erb
  ok   the password is NEVER the literal string "password"
  ...
38 passed, 0 failed
```

It builds a fixture cluster in a temp directory (images, package libraries,
config), reproduces OnDemand's binding — `context` for `script.sh.erb`, bare
locals for `submit.yml.erb` and `view.html.erb` — renders every template, and
asserts on the result. It then bash-parses the job script the template
generates, *and* the rsession wrapper that script writes as a heredoc. Nothing
real is touched.

**"There is no ruby on the cluster" turned out not to be a limit.** This app
already depends on a container runtime; ruby is a 40 MB image and three seconds
away. `test/run.sh` uses the host's ruby if it has one (GitHub Actions does) and
otherwise pulls a container, once. Same tests either way, and CI runs exactly the
same script.

What the suite still cannot catch: OnDemand-specific binding differences, and
anything that only shows up against real Slurm. Those need a Launch — on the
staging app.

### The form discovers images

`form.yml.erb` globs `rstudio-<minor>.sif`, labels each from `images.json`
(`R 4.6.1 · RStudio 2026.06.0+242`), and offers only versions whose package
library actually exists. Two consequences:

- Adding an R version upstream needs no edit here. Run `sync_images --sync`.
- There is **no separate "R packages" dropdown**. The library is a function of
  the image — packages built for one R minor will not load under another — so
  `script.sh.erb` derives it. Previously the two were independent selects, and
  one option pointed at a library directory that did not exist; R ignores a
  missing `R_LIBS_USER` silently, so that failure was invisible.

(`form.yml.bak` is the retired hard-coded form, kept for reference; OnDemand
reads `form.yml.erb`.)

### Running rootless: two things the image needs help with

`rstudio-img` reinstalls the RStudio Server deb on top of the rocker base rather
than letting rocker's `install_rstudio.sh` do it, and does not replay that
script's post-install fixups. Two of those matter when running rootless under
Singularity, and `script.sh.erb` compensates for both:

1. **`/etc/rstudio/database.conf` is `0600 root:root`.** Fine under Docker,
   where you are root. Under Singularity you are not, and **RStudio Server
   2026.06+ treats an unreadable `database.conf` as fatal** where 2025.09 merely
   ignored it. Symptom: `rserver` exits 1 instantly and the session dies with
   `Timed out waiting for RStudio Server to open port`. We write our own
   `database.conf` into `$TMPDIR` and pass `--database-config-file`. Older
   RStudio accepts the same flag, so it is safe across all images.
2. **`logger-type=syslog`** (rocker's default) means there is no syslog in the
   container, so `rserver` startup failures produce *no output at all*. We bind
   a `logging.conf` with `logger-type=stderr` so errors reach the job's
   `output.log`.

The cleaner fix is upstream, in `rstudio-img`'s Dockerfile, after the deb
install — mirroring what rocker does:

```dockerfile
RUN chmod 0644 /etc/rstudio/database.conf \
 && rm -f /var/lib/rstudio-server/secure-cookie-key
```

`database.conf` holds only `provider=sqlite` by default, so widening it to
world-readable leaks nothing. Until that lands, the workarounds above are what
make the images usable rootless.

## Known issues

- **Fixed (2026-07): the session password used to be the literal string
  `password`.** A HACK for idle logouts overwrote the generated random password,
  which — combined with a cluster-reachable rserver port, usernames public in
  `squeue` (jobs are named `rstudio-<slot>`), and a 6000-minute auth window —
  let **any user on the cluster sign into your session and run code as you**.
  The random password is now kept; it reaches the Connect button on its own
  because `password` is one of OnDemand's default connection params, and the
  session card shows the credentials for the rare manual sign-in (see
  [Signing in](#signing-in-there-is-no-password-field-on-purpose)). If idle
  logouts recur, the knob is `--auth-timeout-minutes` in `script.sh.erb`, never
  the password. Sessions launched by an older copy of the app keep the weak
  password until they are relaunched.
