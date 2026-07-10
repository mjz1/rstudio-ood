# RStudio Server (Open OnDemand)

Batch Connect app that launches RStudio Server inside a Singularity container on
a compute node of the `iris` cluster.

The container images are built and published by
[mjz1/rstudio-img](https://github.com/mjz1/rstudio-img) to Docker Hub
(`zatzmanm/rstudio`) and GHCR (`ghcr.io/mjz1/rstudio-img`). Nothing in this app
builds images; it only consumes them.

## How the pieces fit

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

### Shared vs per-user

| Thing | Path | Scope |
|---|---|---|
| Container images | `$RSTUDIO_IMAGE_DIR` (default `~/work/images/rstudio`) | shared artifact |
| R package libraries | `$R_LIBS_ROOT/<minor>_singularity` | **per-user** |

If you are reusing this app, the images can be shared but the R libraries cannot
— see [Reusing this setup](#reusing-this-setup).

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
  `~/work/.rstudio-sessions/<slot>/data`, so concurrent sessions never touch each
  other's open documents, console history, or session registry. Slots live under
  `~/work` (a symlink to `/data1`), **not your space-limited `$HOME`**.
- **The cache and preferences stay shared.** `XDG_CACHE_HOME` (`~/work/.cache`)
  is deliberately *not* per-slot — renv keeps its package library there
  (`$XDG_CACHE_HOME/R/renv`), so isolating it would move every project's library
  out from under `.libPaths()`. `XDG_CONFIG_HOME` (`~/.config`) is shared too, so
  themes/keybindings/settings and your R package library are consistent across
  sessions.
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

- **The Queue dropdown is populated from `RSTUDIO_QUEUES`** (comma-separated, set
  by `install.sh`/config). GPU partitions are **site- and account-specific** —
  on this cluster the shared `gpu` partition *denies* the `shahs3` account, while
  `componc_gpu_batch` / `componc_gpu_int` allow it — so they are configured, not
  hard-coded. Set yours accordingly; see [Reusing this setup](#reusing-this-setup).
- **Each option is labelled with its GPU type and time limit**, so you know what
  you are picking — e.g. `componc_gpu_int — GPU H100/H200 · <=1d · interactive`.
  `install.sh` generates these from Slurm (`scontrol`/`sinfo`) at install time,
  on a login node, and stores them in `RSTUDIO_QUEUES` as `partition|label`
  entries; the form just displays them and submits the bare partition. Labels go
  stale only if a partition's limits change — re-run `install.sh` to refresh.
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

## Reusing this setup

Install straight from the internet — no checkout needed:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/openondemandapps/master/rstudio_dev/install.sh | bash
```

That runs interactively (it reads your answers from the terminal even though the
script arrives over the pipe). To skip the prompts and pass options, add
`bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/openondemandapps/master/rstudio_dev/install.sh \
  | bash -s -- --yes \
      --image-dir /home/zatzmanm/work/images/rstudio \
      --queue componc_cpu \
      --queues componc_cpu,componc_gpu_batch,componc_gpu_int
```

`install.sh` creates your R package libraries, installs the app under
`~/ondemand/dev/`, writes `~/.config/rstudio_dev/config`, and offers to source
the shell wrappers from your `~/.bashrc`. Every answer has a sensible default;
`--dry-run` shows what it would do without touching anything.

**What it does not do**, because it can't: sync the ~16 GB of images (run
`sync-images.sh --sync` after), populate your R libraries (they start empty), or
know your account's GPU partitions (pass them via `--queues`). It installs the
app and writes config — the fast part — and prints the follow-up steps.

Prefer a checkout (for development, or `--link`):

```bash
git clone https://github.com/mjz1/openondemandapps.git
cd openondemandapps/rstudio_dev
./install.sh                                      # interactive
./install.sh --link                               # symlink instead of copy (needs a checkout)
./install.sh --help                               # all options
```

Both paths run the same `install.sh`; the one-liner just fetches the repo first.

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
| `RSTUDIO_VERSIONS` | R minor versions to track when syncing | per-user |
| `RSTUDIO_CLUSTER` | OnDemand cluster id (`/etc/ood/config/clusters.d`) | site |
| `RSTUDIO_QUEUE` | default Slurm partition, pre-selected in the dropdown | site |
| `RSTUDIO_QUEUES` | comma-separated partitions in the Queue dropdown, incl. GPU ones; each entry is `partition` or `partition\|label` (install.sh auto-labels with GPU type + time limit); falls back to `RSTUDIO_QUEUE` if unset | site |
| `RSTUDIO_SYNC_PARTITION` | partition `sync-images.sh` submits pulls to | site |
| `RSTUDIO_TORCH_CUDA` | space-separated R-torch CUDA builds, highest first (default `12.9 12.8 12.6`); the session picks the highest that fits the node driver | site |

`RSTUDIO_STATE_DIR` (default `~/work/.rstudio`) holds RStudio session state and
is read from the environment only.

### What can and cannot be shared

The **images can be shared**; point everyone's `RSTUDIO_IMAGE_DIR` at one
directory, and only whoever runs `sync-images.sh --sync` needs write access.

The **R package libraries cannot**. Packages are compiled against a specific R
minor version and installed into a directory you own, so each user needs their
own `R_LIBS_ROOT` with one `<ver>_singularity` subdirectory per R version. A
version with no library directory is simply not offered by the form — which is
deliberate, since R ignores a missing `R_LIBS_USER` silently.

Your libraries start empty. Install into them from inside RStudio, or:

```bash
Rscript_ -e 'install.packages("data.table")'
```

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
