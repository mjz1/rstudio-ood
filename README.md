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

The app is parameterized on `$HOME`/`$USER`, so a second person needs to change
comparatively little:

1. **Point `R_LIBS_ROOT` at your own library root.** R package libraries cannot
   be shared across users in this layout. Create one directory per R minor
   version you intend to use:
   ```bash
   mkdir -p ~/work/R/x86_64-pc-linux-gnu-library/{4.3,4.4,4.5,4.6}_singularity
   ```
   A version with no library directory is simply not offered by the form.
2. **Point `RSTUDIO_IMAGE_DIR` at the images.** These can be shared read-only;
   only `sync-images.sh` needs write access.
3. `RSTUDIO_STATE_DIR` (default `~/work/.rstudio`) holds RStudio session state.
4. `cluster: "iris"` in `form.yml.erb` and the `queue`/partition defaults are
   site-specific.

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
