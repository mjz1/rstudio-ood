# Developing and deploying

**This repo is not the app directory.** Open OnDemand runs whatever sits in
`~/ondemand/dev/<app>/`; this repo is the source, and installing is a copy —
of the app files only (`APP_FILES` in `install.sh`): the OnDemand templates
plus the bash files whose runtime home is the deployed directory. Repo
tooling (installer, tests, docs, release scripts) stays out of the deploy
target, so the app dir never looks like a checkout.
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
~/ondemand/dev/rstudio_stage_*/ staged branches (./stage.sh), each its own app
```

| Command | Use |
|---|---|
| `./install.sh` | first-time setup: the interview, config, directories, shell wrappers |
| `./install.sh --app-only` | routine deploy: push your edits live, touch nothing else |
| `./stage.sh` | deploy the current branch as its own staging app (`--list`, `--rm BRANCH`, `--prune` to manage) |

## Branching, releases, and how updates reach users

**main is the distribution channel**: `curl | bash` serves it, and the
update notice compares every install against `main/VERSION`. So main holds
released code only, and the workflow follows from that:

| | |
|---|---|
| daily work | on `dev` (feature branches optional, merged to dev) |
| release | `./release.sh X.Y.Z` — suite check, merge dev→main, VERSION stamp, tag, push |
| staging apps | `./stage.sh` on any non-main branch — dev gets "RStudio Server (dev)", `feat/x` gets "(feat/x)" |
| stable app | deploys from `main`: `git switch main && ./install.sh --app-only && git switch dev` |
| `VERSION` | always equals the latest tag; written by release.sh, never by hand |
| `CHANGELOG.md` | every user-visible change adds an `[Unreleased]` entry as it lands; `release.sh` refuses to release without one, then rolls it into the version |

**How users hear about releases:** deploys stamp `.deployed-version` in the app
dir; sessions and `sync_images` compare that stamp against `main/VERSION`
(3-second fetch, silent on any failure) and print a one-line notice with the
update command when they differ. Nothing self-updates — the notice is the whole
mechanism, and it fires only on releases because only releases move main.

Not every merge to dev needs a release — let changes accumulate and cut one
when the bundle is worth a changelog section, or when something must actually
reach users. The `[Unreleased]` section of the changelog is where in-flight
work lives in the meantime.

`--app-only` deliberately skips the interview: redeploying an edit must not be
able to change your storage or partitions behind your back. The staging copy
appears as its own entry in OnDemand, giving you somewhere to click Launch that
isn't the app other people are using.

## Testing the ERB templates

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

## The form discovers images

`form.yml.erb` globs `rstudio-<minor>.sif`, labels each from `images.json`
(`R 4.6.1 · RStudio 2026.06.0+242`), and offers only versions whose package
library actually exists. Two consequences:

- Adding an R version upstream needs no edit here. Run `sync_images --sync`.
- There is **no separate "R packages" dropdown**. The library is a function of
  the image — packages built for one R minor will not load under another — so
  `script.sh.erb` derives it. Previously the two were independent selects, and
  one option pointed at a library directory that did not exist; R ignores a
  missing `R_LIBS_USER` silently, so that failure was invisible.

(The retired hard-coded form lived at `form.yml.bak` until v0.9.7; it is in the
git history if you need it. OnDemand reads `form.yml.erb`.)

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

Back to the [README](../README.md).
