# Installing in detail

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

## Requirements

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

## What it asks you

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

## Trying it safely

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

## What it touches

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

## Sharing images across a lab

One person maintains the image directory; everyone else points at it and never
writes to it.

**The conventional location is auto-discovered.** If
`<lab storage>/users/shared/images/rstudio` exists and holds images (e.g.
`/data1/<lab>/users/shared/images/rstudio`), a plain `./install.sh` finds it
and defaults to it — writable makes you the maintainer, read-only makes you a
consumer. Lab members then need zero image-related flags. The directory should
be group-readable with setgid (`chmod g+rxs`), which the parent `users/shared`
convention usually already provides.

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

## Another cluster, different partitions

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

## Configuration

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

Back to the [README](../README.md).
