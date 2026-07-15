# RStudio Server (Open OnDemand)

An Open OnDemand app that runs RStudio Server inside a Singularity container on a
Slurm compute node. It installs **alongside** whatever R setup you already have
and touches none of it — module R, conda R, your dotfiles and libraries all
behave exactly as before, so trying it risks nothing.

- **One-line install** — an interview that discovers your storage and your
  Slurm partitions; nothing is hard-coded to one person, lab, or cluster.
- **Non-invasive, fully reversible** — no `.Renviron`, `.Rprofile`, `PATH`, or
  R variables are touched, and plain `R` still runs whatever it ran before;
  everything here is active only inside this app's sessions and wrappers
  ([the guarantee](docs/install.md#what-it-does-not-touch--the-coexistence-guarantee)).
  Uninstalling is deleting a config file and an app directory.
- **Current R and RStudio** — images (R 4.3–4.6) rebuilt monthly upstream;
  one command syncs them, and rollback to the previous build is a rename.
- **Named concurrent sessions** — one per project, each resuming its own state;
  labelled in the form, in `squeue`, and on the session card.
- **Lab-shared images** — one person maintains them, everyone else reads them;
  the shared directory is discovered automatically.
- **Per-version package libraries** — the R library is derived from the chosen
  image, so your installed packages can never silently vanish.
- **GPU sessions** *(experimental)* — pick a GPU queue, set GPUs > 0, and
  R `torch` is pointed at the right CUDA build for the node automatically.
- **Terminal wrappers** — `R_`, `Rscript_`, `bash_` run the same images and
  libraries outside OnDemand.

> **Already have R packages on this cluster?** They usually carry over with one
> command — but *which* command depends on how they were built, and copying the
> wrong kind breaks quietly. See
> **[Migrating existing R libraries](docs/install.md#migrating-existing-r-libraries)**
> before your first session.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/main/install.sh | bash
```

That runs an interview (it reads your answers from the terminal even though the
script arrives over a pipe). Answer `?` at any prompt for a full explanation;
add `--dry-run` to preview everything without changing anything.

It asks you **three questions that matter** and discovers the rest (partitions
from Slurm's ACLs, cluster id, container runtime, bind paths):

- **Where do the big directories go?** Images (~16–32 GB), R libraries, session
  state. It proposes large storage it found and warns you off your quota'd home
  directory.
- **Do you maintain the images, or use someone else's?** A lab-shared repo at
  `<lab storage>/users/shared/images/rstudio` is found automatically; point it
  anywhere else if you prefer. Read-only access makes you a consumer — you
  never sync anything.
- **Which rc file** gets the shell wrappers (`R_`, `Rscript_`, `bash_`).

Then reload your shell and pull the images (skip if you use someone else's):

```bash
source ~/.bashrc        # or whatever rc file you chose
sync_images --sync      # submits a Slurm job; ~2 GB per R version
```

and open **Interactive Apps → RStudio Server** in OnDemand:

<p align="center">
  <img src="docs/img/full_rstudio_form.png" width="360"
       alt="The launch form: Session picker, new session name, labelled Queue dropdown, cores/GPUs/hours/memory, and an RStudio image select showing R 4.6.1 with RStudio 2026.06.0">
</p>

**Updating later** is the same one-liner plus `--app-only` — it refreshes the
app files and touches nothing else (not your config, not your libraries):

```bash
curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/main/install.sh | bash -s -- --app-only
```

You don't need to poll for updates: when a newer version exists, the launch
form says so above the Session field, the R console repeats it at session
start, and `sync_images` mentions it. The check is a 3-second, silently-failing
lookup that runs on the compute node — **nothing ever updates itself**, and the
form never makes a network call.

Details — every flag, requirements (incl. the OnDemand "sandbox apps" switch),
what it touches, uninstalling, sharing images across a lab, **migrating
existing R libraries**, other clusters, and the full config reference:
**[docs/install.md](docs/install.md)**.

## Using it

**Signing in.** There is no password field, on purpose: each session gets a
random password, and the **Connect to RStudio Server** button submits it for
you — on every click, so if RStudio ever signs you out, clicking Connect again
puts you straight back in. For the rare manual sign-in, the session card's
*"Signed out of RStudio? Click here."* shows that session's credentials (only
you can see them).

Sessions default to **no `.RData` save/restore** (quit and start are instant;
flip it back in Tools → Global Options if you want the classic behaviour) and
**start in your work directory** on large storage rather than `$HOME`.

**Multiple sessions.** Run several sessions at once, one per project. The form's
**Session** dropdown resumes an existing named slot (state persists: open
documents, console history); **New session name** starts a fresh one. Slots are
isolated per-session, but your packages, renv cache and preferences are shared
across all of them. The Slurm job is named `rstudio-<slot>` and the session card
says which slot it is. One rule: **don't open the same project in two slots at
once** — RStudio locks it.

<p align="center">
  <img src="docs/img/session_dropdown.png" width="430"
       alt="The Session dropdown listing default plus three named slots (test, aml, egfr), each marked 'running now'">
  <img src="docs/img/session_card.png" width="480"
       alt="A running session's card: 16 cores, host, time remaining, 'Session: aml', the Connect to RStudio Server button, and the 'Signed out of RStudio? Click here.' expander">
</p>

**GPUs.** Pick a GPU partition in the Queue dropdown (each option is labelled
with GPU type and time limit), set **Number of GPUs** > 0, and install a
framework in the session:

```r
install.packages("torch"); library(torch)
cuda_is_available()   # TRUE on a GPU node
```

The session automatically points R torch at the right CUDA build for the node's
driver — the image ships no CUDA toolkit, so one image serves CPU and GPU alike.
`libtorch` (~6 GB) lands in your per-R-version library; if you installed the CPU
build first, `torch::install_torch(reinstall = TRUE)` once. How `--nv`, `--gres`
and the CUDA pick actually work: [docs/images.md](docs/images.md) and the
comments in `template/script.sh.erb`.

**AI assistance (Copilot / Posit Assistant).** The image enables two *separate*
integrations, and they are not the same thing:

- **GitHub Copilot** (`copilot-enabled=1`) — RStudio's built-in inline
  completions, backed by the bundled `copilot-language-server`. Sign in under
  **Tools → Global Options → Copilot** with your GitHub account. If your
  institution provides Copilot (MSK does), **this needs no extra credentials
  and no spend — verified working here** for inline completion.
- **Posit Assistant** (`posit-assistant-enabled=1`) — the newer chat/agent pane.
  It prompts to install, then reports *"unable to connect"*, because it is a
  **hosted commercial service**: the backend talks to `gateway.posit.ai`
  (running `claude-sonnet-4-5`) and needs credentials the image cannot supply.
  Two routes exist:
  - **Bring your own key** (0.7.7+): the backend reads `ANTHROPIC_API_KEY` and
    persists settings in `~/.posit/assistant/settings.json` — under `$HOME`, so
    a key set once applies to every session and slot. Set it in the pane's
    settings, or in `~/.Renviron` (`chmod 600` it). Billed to *your* Anthropic
    account.
  - **Posit's AI service** — sign in from the pane; needs a Posit account with
    Assistant access. Untested here, and OAuth callbacks through OnDemand's
    `/rnode/…` proxy are a plausible snag.

  An institutional **GitHub Copilot subscription backs Posit Assistant in
  Positron**; whether RStudio Server can use Copilot as the Assistant's backend
  is **unverified** — if it can, that is the ideal route (no per-token spend,
  institutional identity). Until someone confirms it, native Copilot above is
  the working AI feature and the Assistant pane is decoration. Nothing in this
  app blocks any of it: the backend starts cleanly, the image ships node, and
  compute nodes reach both gateways.

**AI agent access (MCP).** A third, different integration: instead of a chat
pane, it lets a *coding agent you run in the session's Terminal* — Claude Code,
Copilot CLI, any MCP client — see and drive the **live R session**. Set **AI
agent access** on the launch form to **Read-only** or **Read + execute** (Off is
the default and changes nothing). Then, once per project:

```r
install.packages(c("mcptools", "btw"))   # into the project library
```

```bash
rstudio_mcp_init            # writes ./.mcp.json (committable; the lab inherits it)
claude                      # or your agent, run from the project in the Terminal
```

The agent gets tools with **no equivalent in its own toolbox**: list the objects
you have loaded, describe an in-memory data frame, read R help and vignettes for
installed packages, and see the file open in the editor. **Read + execute** adds
`run_r` (the agent runs R *in your session*, against your loaded state, asking
approval each call) and the R-package-development tools (`R CMD check`, tests,
coverage, roxygen docs, `load_all`) — so an agent can build a notebook chunk by
chunk, or iterate on a package, without re-rendering to find each bug. It
deliberately does **not** serve files/git/web tools: your agent already has
better ones, and two ways to do everything makes it pick the worse one.

Why this survives you closing the laptop: the agent, its MCP server and the R
session all run **on the compute node** over node-local sockets — your browser
is only a viewer. Close the tab or sleep the machine and the work continues; on
reconnect, the Terminal may need a **Ctrl+L** to redraw the agent's UI. It ends
only when the job's walltime expires or you quit the session. Which tools are
served is controlled per-launch by the form (via `RSTUDIO_MCP_TOOLS`), so the
`.mcp.json` never needs editing; a read-only session never exposes `run_r`.
Need a lab-specific capability btw lacks? Add an `ellmer::tool()` of your own to
the server command — `mcptools` serves any ellmer tool, not just btw's.

**Shell wrappers.** The same images and libraries from a terminal:

```bash
R_                       # newest R with a populated package library
R_ 4.5                   # a specific R minor
Rscript_ analysis.R      # arguments are forwarded
bash_ -v 4.3             # shell in the container
sync_images              # check the images
rstudio_slots            # list session slots: size, last used, running
```

`rstudio_slots --rm SLOT` resets one named session (its next launch starts
fresh); `--prune` clears slots idle 30+ days. Neither touches your R libraries
or the shared renv cache — packages are never at risk. A slot with a running
session is refused rather than pulled out from under it.

Wrappers get the GPU inside a GPU allocation, share the sessions' renv cache,
and never fall back to another R version's library — a missing library is a
hard error, because R would ignore it silently.

## Keeping images current

`sync_images` (the wrapper for `sync-images.sh`, which is not on `PATH`):

```bash
sync_images                  # check; on a terminal, offers to pull if stale
sync_images --sync           # pull whatever is stale (submits an sbatch job)
sync_images --watch          # follow the running/submitted sync job's log
sync_images --help           # the rest (--local, --image-dir, --manifest)
```

Every run says where it operates (your `RSTUDIO_IMAGE_DIR` — never the current
directory), your maintainer/consumer role, and per image: version, status, and
how long ago it was pulled. Stale images on a terminal end with an offer to
pull; if a sync job is already running you're pointed at it instead of
double-submitting.

<p align="center">
  <img src="docs/img/image_sync.png" width="720"
       alt="sync-images output: the shared image directory and maintainer role in the header, then four green up-to-date rows with R and RStudio versions and pull ages">
</p>

When something is stale, the run ends with the offer:

```
  ! 4.6   STALE       tag moved 9f2c41… -> f24a5d… · pulled 34d ago

  Pull 1 image(s) now (sbatch -> cpushort)? [Y/n]:
```

There is no automation on purpose (the reference cluster has no cron); upstream
rebuilds its rolling tags monthly, so run `sync_images` some time after the 1st.
The previous build of every image is retained — **rollback is a rename**. That,
the registry/digest architecture, and what actually changes between rebuilds:
**[docs/images.md](docs/images.md)**.

## Developing it

This repo is **not** the app directory: OnDemand runs `~/ondemand/dev/<app>`,
and `./install.sh --app-only` deploys the checkout there. Test a branch by
staging it as its own app (`./stage.sh`) rather than on the one your lab uses,
and run `./test/run.sh` before you deploy. The workflow, the staging pattern,
and how the test suite works: **[docs/development.md](docs/development.md)**.

## Known issues

- **`ERROR` lines in a session's log at startup are normal — ignore them.** Two
  appear on every launch, and neither means anything went wrong:
  - `ExperimentalWarning: SQLite is an experimental feature …` — the Posit
    Assistant's Node backend prints this as it starts, and RStudio logs
    *anything* that backend writes as an `ERROR`, warnings included.
  - `Proc stat file: /proc/<pid>/status missing value — found only: 0 of: 2
    keys` — RStudio's memory-usage display asks a helper process how much RAM
    it is using a moment after that process has already exited.

  Both fire once or twice as the session comes up and then stop. They cannot be
  turned down: RStudio emits them at `ERROR`, which is above any log threshold
  the app can set. A session that *genuinely* fails to start does not merely log
  — it never connects.
- **`install.packages()` says a package "is not available" that clearly exists
  on CRAN.** Older R images pin their CRAN mirror to a dated snapshot from
  that R version's era (deliberate; the newest image tracks current CRAN), so
  packages released after that date are invisible there. The fix is one `repos =`
  argument; the whys and the durable options:
  **[docs/images.md](docs/images.md#installing-packages-the-cran-mirror-is-snapshot-pinned)**.
- **Resuming a suspended session can complain `Package 'X' version Y cannot be
  unloaded`.** RStudio restores the suspended R state before renv re-asserts
  the project library, so packages load from your user library first and renv
  then can't swap them for the project's versions. The session keeps running
  with the WRONG (user-library) versions until you fix it — so when you see
  this after a resume: **Session → Restart R** (Ctrl+Shift+F10), which loads
  the right versions cleanly. Idle-suspension is now disabled (sessions own a
  dedicated allocation, so hibernating saves nothing), which removes most
  occurrences; a resume after a relaunch can still hit it once.
- **Sessions launched by a pre-2026-07 copy of the app use a weak, guessable
  password until relaunched** — relaunch them. Current versions keep the random
  per-session password (the session card shows it for the rare manual sign-in).
  If idle logouts ever recur, the knob is `--auth-timeout-minutes` in
  `script.sh.erb` — never the password; the history is in the
  [changelog](CHANGELOG.md).
