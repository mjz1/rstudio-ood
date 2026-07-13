# Images: how the pieces fit

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

## The three directories, and why they are not in your home

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
([how](install.md#sharing-images-across-a-lab)). The R libraries cannot be shared:
packages are compiled against a specific R minor version and installed into a
directory you own.

`install.sh` warns if any of the three lands on your home filesystem — including
under `--yes`, which is the run where nobody was asked anything. It decides by
comparing mount points, not by matching path prefixes, so a `~/work` symlink onto
large storage is correctly recognised as fine.

## Rolling images, and how to roll back

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

Back to the [README](../README.md).
