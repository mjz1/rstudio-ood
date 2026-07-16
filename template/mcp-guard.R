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
  line <- tryCatch(readLines(path, warn = FALSE)[[1]], error = function(e) NULL)
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

# Pure verdict logic, separated for testability. cpu is cores used over the
# sample window; inflight_age is seconds since the sentinel was written (NA if
# none). The busy threshold is deliberately far above the measured wedge
# signature (~0.03 cores) and far below real compute (~1 core).
.mcp_status_verdict <- function(cpu, inflight_age) {
  if (cpu >= 0.15) {
    list(verdict = "busy",
         advice = paste("The session is computing. Wait for the result;",
                        "do not submit further calls -- they queue."))
  } else if (!is.na(inflight_age)) {
    list(verdict = "likely-wedged",
         advice = paste("A run_r call started", round(inflight_age), "s ago,",
                        "never returned, and the session is not computing --",
                        "the signature of code blocked waiting for input.",
                        "Do NOT submit further tool calls (probes corrupt",
                        "recovery). Ask the user to press Esc in the R",
                        "console (Q at a Browse[N]> prompt; click any dialog)."))
  } else {
    list(verdict = "idle",
         advice = "The session is idle and responsive.")
  }
}

# The ellmer tool served by the r-session-status entry.
rstudio_session_status <- function(sample_seconds = 1) {
  ellmer::tool(
    function() {
      pid <- .mcp_find_ancestor("rsession")
      if (is.null(pid)) {
        return(paste("unknown: no rsession ancestor -- this server does not",
                     "appear to be running inside an RStudio session's",
                     "Terminal, so there is no session to observe."))
      }
      s1 <- .mcp_proc_stat(pid)
      Sys.sleep(sample_seconds)
      s2 <- .mcp_proc_stat(pid)
      if (is.null(s1) || is.null(s2)) {
        return(paste("dead: the rsession process (pid", pid, ") disappeared --",
                     "the session or its job has ended. The user must",
                     "relaunch it."))
      }
      cpu <- (s2$utime - s1$utime + s2$stime - s1$stime) / 100 / sample_seconds

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

      v <- .mcp_status_verdict(cpu, inflight_age)
      paste0(
        v$verdict, ": ", v$advice,
        "\n[evidence: rsession pid ", pid, ", state ", s2$state,
        ", cpu ", sprintf("%.3f", cpu), " cores over ", sample_seconds, "s",
        if (!is.na(inflight_age))
          paste0(", unanswered run_r call ", round(inflight_age), "s old"),
        "]"
      )
    },
    name = "rstudio_session_status",
    description = paste(
      "Report whether the live R session is idle, busy computing, likely",
      "wedged, or dead -- WITHOUT touching the session itself (reads /proc",
      "from a separate process, so it works even when the session is",
      "unresponsive). Call this after a run_r timeout instead of probing",
      "with more run_r calls: a timeout alone cannot distinguish a long",
      "computation (be patient, it recovers by itself) from a session",
      "wedged on an input prompt (only a human at the console can clear",
      "it, and further tool calls corrupt the recovery)."
    ),
    arguments = list()
  )
}
