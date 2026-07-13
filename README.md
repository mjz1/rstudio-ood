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

That's it. It runs an interview (reading your answers from the terminal even
though the script arrives over a pipe) and then prints your next steps.

Want to look before you leap — this changes nothing at all:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/master/install.sh | bash -s -- --dry-run
```

The installer asks you **three questions that matter** and works the rest out for
itself:

- **Where do the big directories go?** Container images, your R libraries, and
  session state + caches. It proposes large storage it found (`~/work`,
  `$SCRATCH`, `/data1/*/users/$USER`) and **warns you off your home directory**,
  which is small, quota'd, and shared.
- **Do you maintain the images, or use someone else's?** Point it at a
  colleague's image directory and you never sync anything. Images are identical
  for everyone, so one person can keep them current for a whole lab.
- **Which rc file** gets the shell wrappers (`R_`, `Rscript_`, `bash_`).

Everything else is discovered: your Slurm partitions (from the partition ACLs —
it only offers queues your account may actually submit to, labelled with GPU type
and time limit), the cluster id, the container runtime, and which filesystems
need binding into the container.

Then:

```bash
sync-images.sh --sync    # pull the images (a Slurm job; skip if you're a consumer)
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
everyone — so one person maintains a directory and everyone else reads it. The R
libraries cannot be shared: packages are compiled against a specific R minor
version and installed into a directory you own. See
[Reusing this setup](#reusing-this-setup).

`install.sh` warns if any of the three lands on your home filesystem — including
under `--yes`, which is the run where nobody was asked anything. It decides by
comparing mount points, not by matching path prefixes, so a `~/work` symlink onto
large storage is correctly recognised as fine.

## Keeping images current

```bash
sync-images.sh                  # check only. Three HEAD requests; safe on a login node.
sync-images.sh --sync           # pull whatever is stale (submits an sbatch job)
sync-images.sh --sync 4.6       # restrict to specific versions
sync-images.sh --sync --local   # pull inline, when already inside an allocation
sync-images.sh --manifest       # rebuild images.json from what is on disk
```

The check is cheap and the pull is not — roughly 4 GB plus a squashfs build per
image — so `--sync` submits the pull to Slurm rather than running it on a login
node. If `$SLURM_JOB_ID` is set it runs inline instead, on the assumption you
are already on a compute node.

**If you use someone else's image directory you never run `--sync`.** Checking is
safe for anyone; pulling needs write access. `install.sh` records which you are
(`RSTUDIO_SYNC_ROLE`), and `--sync` refuses up front with an explanation rather
than failing with permission-denied halfway through a 2 GB pull, inside a Slurm
job, in a log you would have to go and find.

This cluster has **no cron available**: `scrontab` is disabled and login-node
`crontab` is blocked by PAM. Sync is therefore a manual step. Since
`rstudio-img` rebuilds rolling tags on the 1st of each month, running
`sync-images.sh` some time after that is enough.

### Rolling images, and how to roll back

Images roll in place: `rstudio-4.5.sif` is overwritten when the registry's `4.5`
tag moves. The outgoing build is retained as `rstudio-4.5.sif.prev` (created as
a hardlink, so it costs no extra disk until the new image lands). To roll back:

```bash
cd "$RSTUDIO_IMAGE_DIR"
mv rstudio-4.5.sif.prev rstudio-4.5.sif
mv rstudio-4.5.sif.prev.digest rstudio-4.5.sif.digest
sync-images.sh --manifest
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

## The form

`form.yml.erb` **discovers** images rather than listing them. It globs
`rstudio-<minor>.sif`, labels each from `images.json` (`R 4.6.1 · RStudio
2026.06.0+242`), and offers only versions whose package library actually exists.

Two consequences:

- Adding an R version upstream needs no edit here. Run `sync-images.sh --sync`.
- There is **no separate "R packages" dropdown**. The library is a function of
  the image — packages built for one R minor will not load under another — so
  `script.sh.erb` derives it. Previously the two were independent selects, and
  the R 4.4 option pointed at a library directory that did not exist. R ignores
  a missing `R_LIBS_USER` silently, so that failure was invisible.

`form.yml.bak` is the retired hard-coded version, kept for reference. It is
inert: OnDemand reads `form.yml.erb`. If your OnDemand is too old to render
`form.yml.erb`, the app will fail visibly — restore with
`mv form.yml.bak form.yml`.

## Multiple concurrent sessions

You can run several RStudio sessions at once — one per project, say — and switch
between them instantly instead of reloading. Each session is an independent
`rserver` on its own node, so the only thing that used to make concurrent
sessions collide was **shared RStudio state in `$HOME`** (`~/.local/share/rstudio`,
the cache, and an abend-reset loop that rewrote *every* running session's state).

Sessions are now isolated by a **named slot**:

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
  named `rstudio-<slot>` so concurrent sessions are distinguishable in `squeue`.
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

## GPU sessions

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
(`R_LIBS_ROOT/<ver>_singularity/torch/lib/`, on `/data1`, ~6 GB extracted), so it
persists across sessions but is **per R minor version** — install it again under
each R you use with a GPU. If you already installed the CPU build, force a
one-time re-download: `torch::install_torch(reinstall = TRUE)` then restart R.

How it works, and why it is built this way:

- **The Queue dropdown is populated from `RSTUDIO_QUEUES`**, which `install.sh`
  *discovers* rather than asking you to type: it reads each partition's
  `AllowAccounts` / `DenyAccounts` / `AllowGroups` and keeps the ones your Slurm
  associations and unix groups actually permit. GPU partitions are site- and
  account-specific — on this cluster the shared `gpu` partition *denies* the
  `shahs3` account while `componc_gpu_batch` / `componc_gpu_int` allow it — so a
  hard-coded list is wrong for everyone but its author.
- **Each option is labelled with its GPU type and time limit**, so you know what
  you are picking — e.g. `componc_gpu_int — GPU H100/H200 · <=1d · interactive`.
  A partition counts as GPU when **every** node in it offers a GPU — not when
  *some* node does, which is true of the CPU partitions too (`cpushort` has 34
  GPU nodes among 235) and would label everything "GPU", and not from its name,
  which is a naming convention rather than a fact. `install.sh` generates the
  labels from Slurm at install time, on a login node, and stores them in
  `RSTUDIO_QUEUES` as `partition|label` entries; the form just displays them and
  submits the bare partition. Labels go stale only if a partition's limits change
  — re-run `install.sh` to refresh.
  You never type the label: `--queues` takes bare partition names.
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
when run inside a GPU allocation (e.g. `salloc --partition=componc_gpu_int
--gres=gpu:1`).

Cluster reference: <https://github.mskcc.org/HPC/userdocs>.

## Shell wrappers

`r-wrappers.sh` provides `R_`, `Rscript_`, `bash_`, and `sync_images` for using
the same images outside OnDemand. Source it from `~/.alias`:

```bash
source "$HOME/ondemand/dev/rstudio_dev/r-wrappers.sh"
```

```bash
R_                       # newest R with a populated package library
R_ 4.5                   # a specific R minor
Rscript_ analysis.R      # arguments are forwarded
Rscript_ -v 4.5 foo.R    # pin the version
bash_ -v 4.3             # shell in the container
```

`R_`/`Rscript_`/`bash_` default to the newest R that has **both** an image and a
non-empty package library — deliberately not `latest`, which tracks the newest
*image*. Pulling a new major R therefore cannot silently strip the packages out
from under an existing script. A missing library is a hard error, never a
fallback to a different R's library.

## Developing and deploying it

**This repo is not the app directory.** Open OnDemand runs whatever sits in
`~/ondemand/dev/<app>/`; this repo is the source, and installing is a copy.

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
able to change your storage or partitions behind your back.

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
submit.yml.erb
  ok   CPU job: no --gres is emitted
  ...
28 passed, 0 failed
```

It builds a fixture cluster in a temp directory (images, package libraries,
config), reproduces OnDemand's binding — `context` for `script.sh.erb`, bare
locals for `submit.yml.erb` — renders every template, and asserts on the result.
It then bash-parses the job script the template generates, *and* the rsession
wrapper that script writes as a heredoc. Nothing real is touched.

**"There is no ruby on the cluster" turned out not to be a limit.** This app
already depends on a container runtime; ruby is a 40 MB image and three seconds
away. `test/run.sh` uses the host's ruby if it has one (GitHub Actions does) and
otherwise pulls a container, once. Same tests either way, and CI runs exactly the
same script.

What the suite still cannot catch: OnDemand-specific binding differences, and
anything that only shows up against real Slurm. So: **test on the staging app**.
Deploying a second copy under a different name gives you somewhere to click
Launch that isn't the app other people are using.

This separation exists because the repo *used to be* the sandbox directory:
`~/ondemand/dev` was the git checkout, so every edit, branch switch and stash was
instantly live. If you find yourself editing files under `~/ondemand/`, you are
editing production — `install.sh` warns if you run it from there.

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

### Trying it safely

`--dry-run` is the honest preview: it prints the config it would write and every
directory it would create, and touches nothing. To go further and run it *for
real* without disturbing an existing setup, redirect the config and every path it
writes into a scratch directory:

```bash
T=$(mktemp -d)
RSTUDIO_DEV_CONFIG=$T/config ./install.sh \
    --storage-root  $T/storage \
    --app-dir       $T/app \
    --shell-init    none        # don't touch any rc file
```

That exercises the whole thing — discovery, the interview, the config file, the
deployed app — against `$T`, leaving your real `~/.config/rstudio_dev/config`,
your OnDemand app and your `~/.bashrc` alone. `rm -rf $T` when you're done.

### What it asks you

1. **A large-storage root.** It proposes one it found (`~/work`, `$SCRATCH`,
   `/data1/*/users/$USER`, …), skipping anything on your home filesystem. The
   three directories default underneath it, and each can be overridden
   separately. It shows free space for each, and pushes back if your answer is on
   the home filesystem.
2. **Whether you maintain images or use someone else's.** If the image directory
   you name is not writable by you, that answer is made for you — you are a
   *consumer*, and `sync-images.sh --sync` will decline rather than fail.
3. **Whether to share your images** with your unix group (`chmod g+rx`). If the
   parent directories block group traversal, it names the offending directories
   instead of leaving you with a `chmod` that appears to have worked but didn't.
4. **Cluster and partitions.** The OnDemand cluster id defaults to Slurm's own
   `ClusterName`. The queue list defaults to *every partition your account may
   submit to*, each labelled with its GPU type and wall-clock limit.
5. **Which rc file** gets the `source .../r-wrappers.sh` line (`none` to skip).
   Under `--yes` this defaults to `~/.bashrc`, and appending there is listed in
   the plan before it happens.

### What it touches

| Path | What |
|---|---|
| `~/.config/rstudio_dev/config` | every setting; **delete this to uninstall** |
| `~/ondemand/dev/rstudio_dev/` | the OnDemand app (copied, or symlinked with `--link`) |
| `$R_LIBS_ROOT/<ver>_singularity/` | one empty library per R version |
| `$RSTUDIO_WORK_DIR/{.rstudio-sessions,.cache}/` | session state and caches |
| `$RSTUDIO_IMAGE_DIR/` | created only if you are the maintainer |
| `~/.bashrc` (or whatever you chose) | one `source` line |

To uninstall: delete the config file and the app directory, and remove that one
`source` line. Your images, libraries and session state are just directories —
delete them if you want the disk back.

**What it deliberately does not do:** pull the images (that is a Slurm job — run
`sync-images.sh --sync` afterwards) or populate your R libraries (they start
empty). It installs the app and writes the config, then prints the follow-up
steps.

### Sharing images across a lab

One person maintains the image directory; everyone else points at it and never
writes to it.

```bash
# maintainer, once
./install.sh --image-dir /data1/lab/shared/rstudio --sync --share-images
sync-images.sh --sync

# everyone else
./install.sh --image-dir /data1/lab/shared/rstudio --no-sync
```

Group read is not enough on its own: every parent directory of the image
directory also needs `g+x`, or your labmates can see the path and still not open
anything in it. `install.sh --share-images` checks the whole chain and tells you
which directories block it.

### Another cluster, different partitions

Nothing needs editing. `install.sh` reads `AllowAccounts` / `DenyAccounts` /
`AllowGroups` off each partition and intersects them with your Slurm
associations and unix groups, so the Queue dropdown offers what you can actually
use and nothing else. (This is not cosmetic: on our cluster the shared `cpu`
partition *denies* most lab accounts, so a hard-coded default of `cpu` produced
jobs that were rejected at submit time.)

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
RSTUDIO_IMAGE_DIR=/tmp/testimages sync-images.sh
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

`RSTUDIO_STATE_DIR` is read from the environment only and now defaults to the
current slot's own state directory (`$RSTUDIO_WORK_DIR/.rstudio-sessions/<slot>/data/rstudio`).
It exists only to scope the "session did not exit cleanly" reset to one slot; it
used to point at a shared `~/work/.rstudio`, which is what made launching one
session clear every other running session's abend flag.

### Your R libraries start empty

`install.sh` creates the library directories but installs nothing into them. Fill
them from inside RStudio, or from a terminal:

```bash
Rscript_ -e 'install.packages("data.table")'
```

An R version with **no** library directory is simply not offered by the form.
That is deliberate: R ignores a missing `R_LIBS_USER` silently, so an image
offered without a matching library would hand you a session where every package
you had installed appeared to have vanished.

## Running rootless: two things the image needs help with

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

- **`template/before.sh.erb` sets the RStudio password to the literal string
  `password`.** It generates a random one with `create_passwd 16` and then
  immediately overwrites it (`password=password`), annotated as a HACK to work
  around losing the session after being idle. The session port is reachable from
  other nodes, so this is worth revisiting — the idle problem is more likely the
  `--auth-timeout-minutes` value, which has since been raised to 6000. Left
  as-is because changing it alters the login flow.
- `sruni`/`scon` in `~/.alias` hardcode `-p interactive` and `scon`'s
  `-p|--partition` branch assigns to `time` rather than `partition`. Unrelated
  to this app, but adjacent.
