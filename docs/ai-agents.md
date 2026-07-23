# AI in a session: three separate integrations

The image ships three things that get called "the AI feature", and they are not
the same thing. They differ in *where the model runs*, *what it can see*, and
*who pays*.

| | What it is | Sees your R session? | Credentials |
|---|---|---|---|
| **GitHub Copilot** | Inline completions in the editor | No — the file you are typing in | Your GitHub account; free on an institutional seat |
| **Posit Assistant** | A chat/agent pane | Limited, through Posit's own plumbing | A hosted service: your API key, or a Posit account |
| **AI agent access (MCP)** | A coding agent *you* run in the Terminal | **Yes — the live session, objects and all** | Whatever your agent already uses |

The first two are RStudio features this app merely enables. The third is built
by this app, is off by default, and is what the rest of this page is about.

## GitHub Copilot

Enabled in the image (`copilot-enabled=1`), backed by the bundled
`copilot-language-server`. Sign in under **Tools → Global Options → Copilot**
with your GitHub account. If your institution provides Copilot (MSK does), this
needs no extra credentials and no per-token spend — **verified working here**
for inline completion. This is the AI feature that works today with no setup
beyond signing in.

## Posit Assistant

The newer chat/agent pane (`posit-assistant-enabled=1`). It prompts to install,
then reports *"unable to connect"*, because it is a **hosted commercial
service**: the backend talks to `gateway.posit.ai` (running
`claude-sonnet-4-5`) and needs credentials the image cannot supply. Two routes:

- **Bring your own key** (0.7.7+): the backend reads `ANTHROPIC_API_KEY` and
  persists settings in `~/.posit/assistant/settings.json` — under `$HOME`, so a
  key set once applies to every session and slot. Set it in the pane's settings
  or in `~/.Renviron` (`chmod 600` it). Billed to *your* Anthropic account.
- **Posit's AI service** — sign in from the pane; needs a Posit account with
  Assistant access. Untested here, and OAuth callbacks through OnDemand's
  `/rnode/…` proxy are a plausible snag.

An institutional **GitHub Copilot subscription backs Posit Assistant in
Positron**; whether RStudio Server can use Copilot as the Assistant's backend is
**unverified** — if it can, that is the ideal route (no per-token spend,
institutional identity). Until someone confirms it, Copilot above is the working
AI feature and this pane is decoration. Nothing in this app blocks any of it:
the backend starts cleanly, the image ships node, and compute nodes reach both
gateways.

## AI agent access (MCP)

Instead of a chat pane, this lets a *coding agent you run in the session's
Terminal* — Claude Code, Copilot CLI, any MCP client — see and drive the **live
R session**, via the `mcptools` + `btw` R packages. Set **AI agent access** on
the launch form to **Read-only** or **Read + execute**; **Off** is the default
and produces a byte-identical session to having none of this.

### What the agent gets

Tools with **no equivalent in its own toolbox**: list the objects you have
loaded, describe an in-memory data frame, read R help and vignettes for
installed packages, and see the file open in the editor.

**Read + execute** adds `run_r` — the agent runs R *in your session, against
your loaded state* — and the R-package-development tools (`R CMD check`, tests,
coverage, roxygen docs, `load_all`). That is what makes it different from an
agent writing code you then paste: it can build a notebook chunk by chunk, or
iterate on a package, without re-rendering to find each bug.

Clients like Claude Code ask your approval on each `run_r` call, but that
per-call consent is the *client's* behaviour — an auto-approving client skips
it, so treat execute mode as "this agent can run code here", not "this agent
will ask".

It deliberately does **not** serve files/git/web tools: your agent already has
better ones, and two ways to do everything makes it pick the worse one.

### Setup, and the two restarts

Once per project, in a session launched with agent access on:

```r
install.packages(c("mcptools", "btw"))   # into the project library
```

```bash
rstudio_mcp_init            # writes ./.mcp.json (committable; the lab inherits it)
claude                      # or your agent, run from the project in the Terminal
```

**Both halves are read exactly once, at startup**, which is why a first run
usually needs two restarts that nothing prompts you for:

- *The session registers with `mcptools` when it starts.* A session that began
  before those packages were installed is **not** registered, no matter what
  you rerun afterwards. After that first `install.packages()`, do **Session →
  Restart R** (Ctrl+Shift+F10). You are registered when the console prints
  `-- MCP: agents in this session's terminal may ... --`; the message `-- AI
  agent access was requested at launch, but package 'mcptools' is not installed
  ... --`, or no message at all, means you are not.
- *Your agent reads `.mcp.json` when it launches.* An agent already running when
  you ran `rstudio_mcp_init` will never see the file. Quit and relaunch it from
  the project directory; in Claude Code, `/mcp` should then list **r-session**
  and **r-session-status**.

**Verify once, because the failure is silent**: an MCP server that finds no
session to connect to does not error — it answers from **its own empty
process**. Ask the agent to list your objects; an empty environment where your
data should be means one of the two restarts is still missing.

### Who decides which tools are served

The launch form does, per session, via `RSTUDIO_MCP_TOOLS` (and the guard's
location in `RSTUDIO_MCP_GUARD`) — so `.mcp.json` is generic and never needs
editing. The same committed file works for every user and every app version.

A read-only session never exposes `run_r`, enforced twice: the execute tools are
filtered out of the served list whatever a config override says, *and*
`BTW_RUN_R_ENABLED=false` is exported explicitly. btw's variable only gates its
*default* tool set — an explicitly named `run_r` is served when the variable is
merely absent, so absence is not safety.

Need a lab-specific capability btw lacks? Add an `ellmer::tool()` of your own to
the server command — `mcptools` serves any ellmer tool, not just btw's.

### Sharing one single-threaded R session

You and the agent share one R process, so nothing ever runs concurrently — tool
calls execute only when the console is idle, and requests serialize.

- *Your code is running* → the agent's tool calls (reads included) **queue
  behind it**; they never interrupt your computation. If the console doesn't
  free up within 120 s the agent gets a clean timeout error instead — so during
  an hours-long fit, the live session is effectively off-limits to the agent.
  Raise `MCPTOOLS_SESSION_RESPONSE_TIMEOUT_SECONDS` if it should wait longer.
- *The agent's code is running* → your console input waits its turn; the session
  feels briefly unresponsive, nothing is lost. The agent's code doesn't echo in
  your console, but its **side effects are shared**: objects it creates, plots
  on your graphics device, options, loaded packages — that's what the per-call
  approval in execute mode is for. **Esc interrupts** whatever R is evaluating,
  an agent's call included.

### Code that prompts for input is dangerous here

The session is single-threaded and the agent's console is not one you can type
into, so a submitted call that asks a question — `devtools`/`renv` "install?
[Y/n]", `askYesNo()`, `menu()` — would block the R thread on a prompt no one can
answer. Because that thread also drives the tool-call event loop, the *whole
session* deadlocks: every later call times out, and no machine can un-wedge it
(the 120 s timeout is server-side and only gives up waiting).

Two layers prevent it:

1. **Execute-mode sessions disarm the common prompts** (`needs.promptUser`,
   `renv.consent`, `askYesNo`) so they raise an immediate **error** rather than
   hang — which the agent sees as a normal tool error. This catches prompts that
   fire from *inside* package code, which no code inspection could see.
2. **The MCP server screens submitted code at the door.** It wraps `run_r`, so
   code is parsed before it reaches the session, and anything that waits for
   console or UI input — `readline`, `scan`, `menu`, `browser`, `readLines()` on
   stdin, `file.choose`, `edit`, `locator`, `rstudioapi::showQuestion` and
   friends — comes back as an explanatory error. It **parses rather than greps**,
   so `# readline() here`, the string `"readline"`, and `readLines("data.txt")`
   all pass untouched. The guard travels with the tool, so every client of this
   server inherits it.

The guard protects *this* server only: a hand-rolled `mcptools::mcp_server()`,
or a `.mcp.json` written before the guard existed, serves `run_r` bare. Re-run
`rstudio_mcp_init` — it detects a pre-guard file and prints the replacement
entry.

Neither layer can see through indirection (`do.call`, `eval(parse())`) or into a
`source()`d file, so prefer non-interactive calls: `library()` or
`pkgload::load_all(attach = FALSE)` over `devtools::load_all()`.

### Recovering a wedged session

**A human at the console recovers it** (verified live): **Esc** interrupts a
blocked `readline()` or dialog, **clicking** answers an `rstudioapi` modal, and
**`Q`** exits a `browser()` wedge — the debugger prompt works normally
throughout. There is no machine path: the MCP transport carries code in and
output out, and can neither answer a prompt nor interrupt one, so an unattended
run stalls at the wedge until someone comes back.

While it waits, **leave the session alone**. Probing a wedged session with
further tool calls is not a free read: queued callbacks can error during
recovery and corrupt console input. Treat a call that timed out as possibly
lost, and save diagnostics for after the human has cleared the console.

### `rstudio_session_status`: the one free probe

One probe *is* free. `rstudio_session_status` is served by a second, separate
server (`r-session-status`, written into the same `.mcp.json`) that **never
connects to the session** — it reads `/proc` from its own process, so it keeps
answering while the session is wedged. This is what an agent should call after a
timeout, instead of retrying.

It crosses the session's CPU, its **children's** CPU (a `system()` call running
an aligner looks idle from the session itself), whether a `run_r` call is still
unanswered, and — via `/proc/<pid>/syscall` — what the session is blocked in:

| Verdict | Meaning |
|---|---|
| `idle` | Console free, nothing outstanding |
| `busy` | The session itself is computing |
| `busy-subprocess` | A child process is computing; the session looks idle but is not |
| `waiting-timer` | A **pure sleep** (`nanosleep`) — self-clearing, no action |
| `waiting-io` | Uninterruptible disk I/O — a transfer, not a wedge |
| `waiting` | Blocked on something ambiguous; evidence and advice included |
| `dead` | The rsession process is gone |

It is deliberately cautious about what it calls self-clearing. Only a pure sleep
gets `waiting-timer`. Everything else — a `poll`/`select` **with** a timeout
(which looks identical whether it is a `Sys.sleep` or an event loop wedged
forever), an indefinite wait, or a blocking read — falls to bare `waiting`,
where the advice names the syscall and hands the judgement to the agent: it
knows the code it submitted, so I/O-ish or sleeping code means wait, while pure
computation or possibly-prompting code means get the user to press Esc. Erring
toward "ask the agent" over a confident "just wait" is intentional — telling
someone to wait forever on a wedged session is the worse mistake.

Two notes: the status server errors at startup when the agent runs *outside* any
session (nothing to observe — expected, not a breakage), and the durable fix
(per-call timeout and cancellation) still belongs upstream in `mcptools`/`btw`.

### Why this survives you closing the laptop

The agent, its MCP server and the R session all run **on the compute node**,
over node-local unix sockets — your browser is only a viewer. Close the tab or
sleep the machine and the work continues; on reconnect, the Terminal may need a
**Ctrl+L** to redraw the agent's UI. It ends only when the job's walltime
expires or you quit the session.

No network ports are involved, which is also why there is no login-node or
cross-node variant: the transport is local by nature.
