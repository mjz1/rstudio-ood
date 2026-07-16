# mcp-guard.R -- block session-wedging calls before they reach the R session.
#
# Sourced by the MCP server command in a project's .mcp.json (written by
# rstudio_mcp_init). It wraps btw's run_r tool so submitted code is parsed and
# screened BEFORE evaluation: anything that waits for console or UI input is
# refused with an explanatory error instead of deadlocking the session.
#
# WHY THIS EXISTS. The session is single-threaded and mcptools dispatches tool
# calls as `later` callbacks on its event loop. Code that prompts for input --
# readline(), menu(), browser(), an rstudioapi dialog -- blocks the main thread
# on a console nobody is typing into, so the event loop never resumes and EVERY
# later tool call times out. Recovery needs a human at the console (Esc / click
# / Q); there is no machine path, and a probe from the agent makes it worse.
# Measured and documented in issue #2. The session-side options() in
# script.sh.erb catch the *hookable* prompts (devtools/renv/askYesNo, which fire
# from deep inside package code); this catches the *direct* calls an agent
# writes, which no option can reach.
#
# WHY A WRAPPER AND NOT A CLIENT HOOK. A Claude Code PreToolUse hook would work
# only for Claude Code. mcptools serialises the tool object into the request and
# ships it to the session (server.R: `data$tool <- get_mcptools_tools()[[name]]`
# then `serialize(prepared, NULL)`), so a wrapper here travels with the tool and
# guards EVERY MCP client -- Claude Code, Copilot CLI, anything.
#
# THE SERIALISATION TRAP, verified experimentally. Because the wrapper is
# serialised and re-executed in the SESSION's process, its closure environment
# travels with it -- but R serialises globalenv and namespaces BY REFERENCE.
# A helper defined at this file's top level would be looked up in the SESSION's
# globalenv, where it does not exist: "could not find function". So the wrapper
# and everything it touches are sealed inside local(), whose environment
# serialises BY VALUE. Do not hoist these helpers to the top level.

guard_btw_tools <- function(tools) {
  if (!length(tools)) return(tools)
  for (i in seq_along(tools)) {
    nm <- tryCatch(tools[[i]]@name, error = function(e) "")
    if (identical(nm, "btw_tool_run_r")) {
      tools[[i]] <- .guard_run_r(tools[[i]])
    }
  }
  tools
}

# Replace the tool's underlying function with a screening wrapper, keeping every
# ToolDef property (name/description/arguments/convert/annotations) untouched --
# S7_data<- swaps only the function the ToolDef *is*.
.guard_run_r <- function(tool) {
  original <- S7::S7_data(tool)
  S7::S7_data(tool) <- local({
    orig <- original

    # Calls that park the R main thread on input nobody can supply.
    # Values are the message fragment explaining the specific hazard.
    blocked <- list(
      readline       = "readline() waits for console input",
      readLines      = "readLines() on stdin waits for console input",
      scan           = "scan() reads from the console when no file=/text= is given",
      menu           = "menu() waits for a console selection",
      select.list    = "select.list() waits for a selection",
      askYesNo       = "askYesNo() waits for a console answer",
      browser        = "browser() drops into the debugger and waits for input",
      recover        = "recover() waits for a frame selection",
      file.choose    = "file.choose() opens a modal file dialog",
      edit           = "edit() opens a blocking editor",
      fix            = "fix() opens a blocking editor",
      locator        = "locator() waits for clicks on the plot",
      identify       = "identify() waits for clicks on the plot",
      getPass        = "getPass::getPass() waits for masked input",
      showQuestion   = "rstudioapi::showQuestion() opens a modal dialog",
      showPrompt     = "rstudioapi::showPrompt() opens a modal dialog",
      askForPassword = "rstudioapi::askForPassword() opens a modal dialog",
      askForSecret   = "rstudioapi::askForSecret() opens a modal dialog",
      selectFile     = "rstudioapi::selectFile() opens a modal file chooser",
      selectDirectory = "rstudioapi::selectDirectory() opens a modal file chooser"
    )

    # Pick an argument from an unevaluated call by EXACT name, else (when pos
    # is given) by position among the unnamed args. as.list(expr)$name would
    # partial-match (args$file happily returns fileEncoding=), which misread
    # scan() once. Returns NULL when the argument is absent.
    call_arg <- function(expr, name, pos = NULL) {
      args <- as.list(expr)[-1]
      nms <- names(args)
      if (is.null(nms)) nms <- rep("", length(args))
      i <- which(nms == name)
      if (length(i)) return(args[[i[[1]]]])
      if (!is.null(pos)) {
        unnamed <- which(nms == "")
        if (length(unnamed) >= pos) return(args[[unnamed[[pos]]]])
      }
      NULL
    }

    # TRUE when an argument expression means "the console": absent (the
    # default con=stdin() / file="" reads it), the literal "stdin", a call to
    # stdin(), or file("stdin").
    is_console_source <- function(arg) {
      if (is.null(arg)) return(TRUE)
      if (is.character(arg)) return(identical(arg, "stdin") || identical(arg, ""))
      if (is.call(arg) && is.name(arg[[1]])) {
        fn <- as.character(arg[[1]])
        if (identical(fn, "stdin")) return(TRUE)
        if (identical(fn, "file")) {
          desc <- call_arg(arg, "description", 1L)
          return(is.null(desc) || identical(desc, "stdin") || identical(desc, ""))
        }
      }
      FALSE
    }

    # Walk the AST for CALLS to blocked functions. Parsing (not grepping) is
    # what keeps false positives out: comments vanish, string literals are not
    # calls, and grepl("menu", x) passes because `menu` there is data.
    # readLines()/scan() are only hazards on the console, so they are judged
    # on their arguments -- and judged CONSERVATIVELY in opposite directions:
    # readLines blocks only when the connection is recognisably the console
    # (its named source), while scan passes whenever file=/text= is supplied
    # AS ANYTHING (a variable or call cannot be resolved statically, and
    # refusing every scan(fname) would make the tool useless for real work).
    find_blocked <- function(expr, found = character()) {
      if (is.call(expr)) {
        fn <- expr[[1]]
        # bare f(), pkg::f() and pkg:::f() all reduce to the same leaf name.
        # fn[[1]] must be tested with is.name BEFORE as.character: in
        # pkg::f(a, b)(x) the function position is itself a 3-long call whose
        # own head is a call, and as.character() on that returns a length-3
        # vector that && rejects with a coercion error (R >= 4.3).
        if (is.call(fn) &&
            length(fn) == 3L &&
            is.name(fn[[1]]) &&
            as.character(fn[[1]]) %in% c("::", ":::")) {
          fn <- fn[[3]]
        }
        if (is.name(fn)) {
          nm <- as.character(fn)
          if (nm %in% names(blocked)) {
            hazard <- TRUE
            if (identical(nm, "readLines")) {
              hazard <- is_console_source(call_arg(expr, "con", 1L))
            }
            if (identical(nm, "scan")) {
              file <- call_arg(expr, "file", 1L)
              text <- call_arg(expr, "text")   # 21st formal: named-only
              file_is_console <- is.null(file) ||
                (is.character(file) && !nzchar(file))
              hazard <- file_is_console && is.null(text)
            }
            if (hazard) found <- c(found, nm)
          }
        }
      }
      if (is.recursive(expr)) {
        for (part in as.list(expr)) {
          if (!missing(part)) found <- find_blocked(part, found)
        }
      }
      unique(found)
    }

    # In-flight sentinel for the session_status tool: written before the eval,
    # removed after. A wedged eval never reaches the removal, so a persisting
    # sentinel + flat CPU is the "likely wedged" signature; an Esc-interrupted
    # eval unwinds through on.exit and cleans up. The path is resolved at WRAP
    # time in the server process (where RSTUDIO_MCP_GUARD is set) into a plain
    # string, which serialises by value like everything else in this seal.
    sentinel <- {
      g <- Sys.getenv("RSTUDIO_MCP_GUARD")
      if (nzchar(g)) file.path(dirname(g), ".run_r-inflight") else ""
    }

    function(code, `_intent` = NULL) {
      exprs <- tryCatch(parse(text = code), error = function(e) NULL)
      # Unparseable code is not our problem to report -- hand it to btw, whose
      # error message for a syntax error is better than anything we'd invent.
      if (!is.null(exprs)) {
        hits <- character()
        for (e in as.list(exprs)) hits <- unique(c(hits, find_blocked(e)))
        if (length(hits)) {
          stop(
            "blocked before reaching the R session: ",
            paste(vapply(hits, function(h) blocked[[h]], character(1)),
                  collapse = "; "),
            ".\nThe session is single-threaded, so a call that waits for input ",
            "deadlocks it for every later tool call, and only a human at the ",
            "console can clear it. Rewrite this non-interactively (pass the ",
            "value as an argument, use library() or ",
            "pkgload::load_all(attach = FALSE) instead of devtools::load_all()), ",
            "or ask the user to run this chunk in their console themselves.",
            call. = FALSE
          )
        }
      }
      if (nzchar(sentinel)) {
        tryCatch(writeLines(format(Sys.time()), sentinel),
                 error = function(e) NULL)
        on.exit(tryCatch(unlink(sentinel), error = function(e) NULL),
                add = TRUE)
      }
      orig(code = code, `_intent` = `_intent`)
    }
  })
  tool
}

# ---------------------------------------------------------------------------
# session_status: is the R session idle, busy, or wedged?
#
# Served by the SECOND .mcp.json entry (r-session-status) with
# session_tools = FALSE, which makes mcptools run its tools in the server's
# own process -- once a session connection exists, the primary server forwards
# EVERY tool call to the session (server.R dispatch allowlists only
# list/select_r_sessions), so a status tool there would queue behind the very
# wedge it is meant to diagnose. This one reads /proc from a separate process
# on the same node: it works PRECISELY when the session is wedged, and it is
# the one probe that is genuinely free -- it never touches the session's
# event loop. (These helpers run server-side only and are never serialised
# into the session, so they may live at the file's top level.)
#
# The verdict crosses two signals, because neither alone is enough:
#   - /proc CPU delta: climbing utime = computing; flat = idle OR wedged.
#   - the in-flight sentinel (written by the guarded run_r around each eval):
#     present and old = a call that never returned.
# flat CPU + in-flight call = likely wedged (measured signature of the real
# deadlock: state S, ~0% CPU, flat utime). A timeout alone proves nothing --
# long computations outlive the client timeout and recover by themselves.

# Parse /proc/<pid>/stat. comm (field 2) may contain spaces or parens, so
# fields resume after the LAST close-paren.
.mcp_proc_stat <- function(pid) {
  path <- sprintf("/proc/%d/stat", as.integer(pid))
  line <- tryCatch(suppressWarnings(readLines(path, warn = FALSE)[[1]]),
                   error = function(e) NULL)
  if (is.null(line)) return(NULL)
  cp <- max(gregexpr(")", line, fixed = TRUE)[[1]])
  rest <- strsplit(trimws(substring(line, cp + 1L)), " +")[[1]]
  list(
    comm  = sub("^[0-9]+ \\(", "", substring(line, 1L, cp - 1L)),
    state = rest[[1]],
    ppid  = as.integer(rest[[2]]),
    utime = as.numeric(rest[[12]]),   # field 14
    stime = as.numeric(rest[[13]]),   # field 15
    starttime = as.numeric(rest[[20]])  # field 22, in ticks since boot
  )
}

# Walk up the parent chain to the enclosing process named `target`. The status
# server runs in the session's Terminal, so rsession is always an ancestor;
# with several sessions on one node this still finds OUR one.
.mcp_find_ancestor <- function(target, from = Sys.getpid(), max_depth = 40L) {
  pid <- from
  for (i in seq_len(max_depth)) {
    st <- .mcp_proc_stat(pid)
    if (is.null(st)) return(NULL)
    if (identical(st$comm, target)) return(pid)
    if (is.na(st$ppid) || st$ppid <= 1L) return(NULL)
    pid <- st$ppid
  }
  NULL
}

# What syscall is the process blocked in, and is it a TIMED wait? Read from
# /proc/<pid>/syscall ("NR a0 a1 a2 a3 a4 a5 sp pc"), which is a reliable
# number here (wchan symbolises only some waits -- it is "hrtimer_nanosleep"
# for coreutils sleep but "0" for R's Sys.sleep, which is pselect6). Returns
# name + `timed`: TRUE for a wait that returns on its own (a sleep, or a
# select/poll with a finite timeout -- this is what R's Sys.sleep and polling
# loops look like), FALSE for a blocking read (console input, or a network
# read that clears when data arrives), NA when unreadable.
#
# x86_64 syscall numbers. The arg holding the timeout differs per call, and a
# NULL pointer / -1 there means "wait forever" -- so pselect6 with a non-NULL
# timeout is Sys.sleep, pselect6 with NULL is an indefinite wait (a possible
# wedge). This is what separates "be patient" from "get a human".
.mcp_proc_syscall <- function(pid) {
  path <- sprintf("/proc/%d/syscall", as.integer(pid))
  line <- tryCatch(suppressWarnings(readLines(path, warn = FALSE)[[1]]),
                   error = function(e) NULL)
  if (is.null(line) || identical(line, "running") || !nzchar(line))
    return(list(name = NA_character_, timed = NA))
  f <- strsplit(trimws(line), " +")[[1]]
  nr <- suppressWarnings(as.integer(f[[1]]))
  if (is.na(nr)) return(list(name = NA_character_, timed = NA))
  arg <- function(i) if (length(f) >= i + 2L) f[[i + 2L]] else "0x0"  # a<i>, 0-based
  nonnull <- function(x) !is.null(x) && !x %in% c("0x0", "0xffffffffffffffff")
  names <- c("0"="read","17"="pread64","19"="readv","45"="recvfrom",
             "47"="recvmsg","299"="recvmmsg","35"="nanosleep",
             "230"="clock_nanosleep","23"="select","270"="pselect6",
             "7"="poll","271"="ppoll","232"="epoll_wait","281"="epoll_pwait")
  name <- unname(names[as.character(nr)])   # single-bracket: NA when unmapped
  if (is.na(name)) name <- paste0("syscall_", nr)
  timed <- switch(name,
    nanosleep = , clock_nanosleep = TRUE,
    select = , pselect6 = nonnull(arg(4)),   # timeout = 5th arg (a4)
    ppoll = nonnull(arg(2)),                  # timeout ptr = a2
    poll = , epoll_wait = , epoll_pwait = nonnull(arg(if (name == "poll") 2 else 3)),
    read = , pread64 = , readv = , recvfrom = , recvmsg = , recvmmsg = FALSE,
    NA)
  list(name = name, timed = timed)
}

# One /proc pass: pid -> (ppid, cpu ticks). Two of these bracket the sample
# window so descendant CPU can be measured alongside the session's own.
.mcp_proc_snapshot <- function() {
  pids <- list.files("/proc", pattern = "^[0-9]+$")
  out <- new.env(parent = emptyenv())
  for (p in pids) {
    st <- .mcp_proc_stat(p)
    if (!is.null(st)) assign(p, c(st$ppid, st$utime + st$stime), envir = out)
  }
  out
}

# Cores burned over the window by DESCENDANTS of root, excluding the pids on
# `exclude` (our own ancestry chain: the Terminal shell, the agent, this very
# server -- all descendants of rsession that are not the session's work). A
# session inside system()/system2() has ~0 CPU itself while its CHILD does the
# work -- samtools, an aligner, a compiler -- and without this signal that
# reads as "not computing", one flat sample away from telling the user to Esc
# a healthy pipeline.
.mcp_subtree_cpu <- function(root, exclude, snap1, snap2, secs) {
  kids_of <- function(snap) {
    m <- new.env(parent = emptyenv())
    for (p in ls(snap)) {
      pp <- as.character(get(p, envir = snap)[[1]])
      assign(pp, c(if (exists(pp, envir = m)) get(pp, envir = m), p), envir = m)
    }
    m
  }
  m2 <- kids_of(snap2)
  seen <- character(); queue <- as.character(root)
  while (length(queue)) {
    p <- queue[[1]]; queue <- queue[-1]
    for (k in if (exists(p, envir = m2)) get(p, envir = m2) else character()) {
      if (k %in% seen || k %in% as.character(exclude)) next
      seen <- c(seen, k); queue <- c(queue, k)
    }
  }
  ticks <- 0
  for (p in seen) {
    if (exists(p, envir = snap1) && exists(p, envir = snap2)) {
      d <- get(p, envir = snap2)[[2]] - get(p, envir = snap1)[[2]]
      if (is.finite(d) && d > 0) ticks <- ticks + d
    }
  }
  ticks / 100 / secs
}

# Pure verdict logic, separated for testability. cpu / subtree_cpu are cores
# used over the sample window (session itself / its descendants minus our own
# chain); inflight_age is seconds since the sentinel was written (NA if none);
# state is the /proc state letter; syscall is .mcp_proc_syscall()'s
# list(name, timed). The busy threshold is deliberately far above the measured
# wedge signature (~0.03 cores) and far below real compute (~1 core).
#
# The crucial honesty: flat CPU + an unanswered call does NOT prove a wedge.
# system()/download.file()/DBI/Sys.sleep all look similar from here (the first
# review shipped "likely-wedged: press Esc" for that state -- advice that
# aborts a healthy pipeline; the second live test found Sys.sleep landing in
# the generic branch because it is pselect6, not nanosleep, and wchan reads 0).
# The signals that DO separate the cases: state D = disk I/O; a computing child
# = subprocess; a TIMED syscall (sleep, or select/poll with a finite timeout) =
# a self-clearing wait, which is what Sys.sleep and polling loops actually look
# like; a blocking READ = console input OR a network read, still ambiguous ->
# hand that last one to the AGENT, which knows the code it submitted.
.mcp_status_verdict <- function(cpu, inflight_age, state = "S",
                                syscall = list(name = NA, timed = NA),
                                subtree_cpu = 0) {
  if (cpu >= 0.15) {
    return(list(verdict = "busy",
                advice = paste("The session is computing. Wait for the",
                               "result; do not submit further calls --",
                               "they queue.")))
  }
  if (!is.na(inflight_age) && subtree_cpu >= 0.15) {
    return(list(verdict = "busy-subprocess",
                advice = paste("The session itself is quiet but a child",
                               "process of it is computing -- the submitted",
                               "code is running an external tool (system(),",
                               "a compiler, an aligner). Legitimate work:",
                               "wait and re-check; do not interrupt.")))
  }
  if (!is.na(inflight_age)) {
    # A timed wait clears itself; disk I/O is a transfer, not a wedge. Both
    # get a WAIT verdict with no Esc. Only the genuinely ambiguous "blocked
    # reading input" case defers to the agent and mentions Esc.
    if (isTRUE(identical(state, "D"))) {
      return(list(verdict = "waiting-io",
                  advice = paste0(
                    "A run_r call started ", round(inflight_age), "s ago and ",
                    "the session is in state D (uninterruptible disk I/O) -- ",
                    "a large read/write, NOT a wedge. Wait and re-check; do ",
                    "not interrupt.")))
    }
    if (isTRUE(syscall$timed)) {
      return(list(verdict = "waiting-timer",
                  advice = paste0(
                    "A run_r call started ", round(inflight_age), "s ago and ",
                    "the session is in a timed wait (", syscall$name,
                    " with a timeout -- Sys.sleep, or a poll/select loop), ",
                    "which returns on its own. This is NOT a wedge and needs ",
                    "no user action: just wait and call this tool again ",
                    "later to confirm it finished.")))
    }
    reading <- isFALSE(syscall$timed) && !is.na(syscall$name)
    return(list(verdict = "waiting",
                advice = paste0(
                  "A run_r call started ", round(inflight_age), "s ago, has ",
                  "not returned, and the session is not computing",
                  if (reading) paste0(" -- it is blocked in ", syscall$name,
                                      "(), reading something") else "",
                  ". YOU know the code you submitted: if it plausibly does ",
                  "I/O, a network/database read, subprocesses, or sleeps, this ",
                  "is expected -- wait and call this tool again later. If it ",
                  "was pure computation, or could have prompted for input ",
                  "(interactive calls can slip in via source()/do.call()), ",
                  "treat it as wedged: do NOT probe with more tool calls, ",
                  "and ask the user to press Esc in the R console (Q at a ",
                  "Browse[N]> prompt; click any dialog).")))
  }
  list(verdict = "idle",
       advice = "The session is idle and responsive.")
}

# Locate the rsession pid. RSTUDIO_SESSION_PID (exported by the rsession
# wrapper, so it IS the session's pid and every Terminal child inherits it) is
# preferred: the ancestry walk assumes the chain shell<-agent<-server stays
# unbroken and the process is named exactly "rsession", both of which client
# spawning strategies can silently violate. The env var also makes "dead"
# detectable -- a pid we can still name after the process is gone -- where the
# walk could only shrug "unknown". Validated before trust (pid recycling,
# stale env after a session restart); the walk remains as fallback for
# sessions launched before the export existed.
.mcp_rsession_pid <- function() {
  env <- suppressWarnings(as.integer(Sys.getenv("RSTUDIO_SESSION_PID")))
  if (!is.na(env) && env > 1) {
    st <- .mcp_proc_stat(env)
    if (!is.null(st) && identical(st$comm, "rsession")) {
      return(list(pid = env, source = "env"))
    }
    walked <- .mcp_find_ancestor("rsession")
    if (!is.null(walked)) return(list(pid = walked, source = "walk"))
    # The wrapper named a pid and it is gone (or recycled into something
    # else), and no rsession ancestor exists either: the session died.
    return(list(pid = env, source = "env-dead"))
  }
  walked <- .mcp_find_ancestor("rsession")
  if (!is.null(walked)) return(list(pid = walked, source = "walk"))
  NULL
}

# The ellmer tool served by the r-session-status entry.
rstudio_session_status <- function(sample_seconds = 1) {
  ellmer::tool(
    function() {
      loc <- .mcp_rsession_pid()
      if (is.null(loc)) {
        return(paste("unknown: no rsession found by pid or ancestry -- this",
                     "server does not appear to be running inside an RStudio",
                     "session's Terminal, so there is no session to observe."))
      }
      if (identical(loc$source, "env-dead")) {
        return(paste("dead: the rsession process (pid", loc$pid, ") no longer",
                     "exists -- the session or its job has ended. The user",
                     "must relaunch it."))
      }
      pid <- loc$pid
      s1 <- .mcp_proc_stat(pid)
      snap1 <- .mcp_proc_snapshot()
      Sys.sleep(sample_seconds)
      s2 <- .mcp_proc_stat(pid)
      snap2 <- .mcp_proc_snapshot()
      if (is.null(s1) || is.null(s2)) {
        return(paste("dead: the rsession process (pid", pid, ") disappeared --",
                     "the session or its job has ended. The user must",
                     "relaunch it."))
      }
      cpu <- (s2$utime - s1$utime + s2$stime - s1$stime) / 100 / sample_seconds
      syscall <- .mcp_proc_syscall(pid)

      # our own ancestry chain (this server up to rsession): descendants of
      # the session, but not the session's WORK -- excluded from subtree CPU
      chain <- integer(); p <- Sys.getpid()
      for (i in 1:40) {
        chain <- c(chain, p)
        st <- .mcp_proc_stat(p)
        if (is.null(st) || is.na(st$ppid) || st$ppid <= 1L ||
            st$ppid == pid) break
        p <- st$ppid
      }
      subtree_cpu <- .mcp_subtree_cpu(pid, chain, snap1, snap2, sample_seconds)

      # sentinel written by the guarded run_r; ignore one that predates the
      # rsession process itself (leftover from a crashed predecessor).
      inflight_age <- NA_real_
      g <- Sys.getenv("RSTUDIO_MCP_GUARD")
      if (nzchar(g)) {
        sent <- file.path(dirname(g), ".run_r-inflight")
        if (file.exists(sent)) {
          uptime <- as.numeric(strsplit(readLines("/proc/uptime",
                                                  warn = FALSE), " ")[[1]][[1]])
          proc_start <- as.numeric(Sys.time()) - uptime + s2$starttime / 100
          mt <- as.numeric(file.mtime(sent))
          if (mt >= proc_start - 1) inflight_age <- as.numeric(Sys.time()) - mt
        }
      }

      v <- .mcp_status_verdict(cpu, inflight_age, s2$state, syscall, subtree_cpu)
      paste0(
        v$verdict, ": ", v$advice,
        "\n[evidence: rsession pid ", pid, " (via ", loc$source, ")",
        ", state ", s2$state,
        ", cpu ", sprintf("%.3f", cpu),
        " + children ", sprintf("%.3f", subtree_cpu),
        " cores over ", sample_seconds, "s",
        if (!is.na(syscall$name))
          paste0(", syscall ", syscall$name,
                 if (!is.na(syscall$timed))
                   paste0(" (", if (syscall$timed) "timed" else "blocking", ")")),
        if (!is.na(inflight_age))
          paste0(", unanswered run_r call ", round(inflight_age), "s old"),
        "]"
      )
    },
    name = "rstudio_session_status",
    description = paste(
      "Report what the live R session is doing: idle, busy (computing),",
      "busy-subprocess (a child like system() is computing), waiting-timer",
      "(a self-clearing Sys.sleep/poll -- no action needed), waiting-io (a",
      "disk transfer), waiting (an unanswered call blocked on input, which",
      "may be a wedge -- evidence and advice included), or dead -- WITHOUT",
      "touching the session itself (reads",
      "/proc from a separate process, so it works even when the session is",
      "unresponsive). Call this after a run_r timeout instead of probing",
      "with more run_r calls: a timeout alone cannot distinguish a long",
      "computation (be patient, it recovers by itself) from a session",
      "wedged on an input prompt (only a human at the console can clear",
      "it, and further tool calls corrupt the recovery)."
    ),
    arguments = list()
  )
}
