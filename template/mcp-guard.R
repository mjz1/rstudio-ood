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
      scan           = "scan() reads from the console when no file= is given",
      menu           = "menu() waits for a console selection",
      select.list    = "select.list() waits for a selection",
      browser        = "browser() drops into the debugger and waits for input",
      recover        = "recover() waits for a frame selection",
      showQuestion   = "rstudioapi::showQuestion() opens a modal dialog",
      showPrompt     = "rstudioapi::showPrompt() opens a modal dialog",
      askForPassword = "rstudioapi::askForPassword() opens a modal dialog",
      askForSecret   = "rstudioapi::askForSecret() opens a modal dialog",
      selectFile     = "rstudioapi::selectFile() opens a modal file chooser",
      selectDirectory = "rstudioapi::selectDirectory() opens a modal file chooser"
    )

    # Walk the AST for CALLS to blocked functions. Parsing (not grepping) is
    # what keeps false positives out: comments vanish, string literals are not
    # calls, and grepl("menu", x) passes because `menu` there is data.
    # readLines() is only a hazard on stdin, so it is judged on its argument.
    find_blocked <- function(expr, found = character()) {
      if (is.call(expr)) {
        fn <- expr[[1]]
        # bare f(), pkg::f() and pkg:::f() all reduce to the same leaf name
        if (is.call(fn) &&
            length(fn) == 3L &&
            as.character(fn[[1]]) %in% c("::", ":::")) {
          fn <- fn[[3]]
        }
        if (is.name(fn)) {
          nm <- as.character(fn)
          if (nm %in% names(blocked)) {
            hazard <- TRUE
            if (identical(nm, "readLines")) {
              # only stdin blocks; readLines("file.txt") is fine
              args <- as.list(expr)[-1]
              con <- if (!is.null(args$con)) args$con else if (length(args)) args[[1]] else ""
              hazard <- is.character(con) && identical(con, "stdin")
            }
            if (identical(nm, "scan")) {
              # scan(file="x") reads a file; bare scan() reads the console
              args <- as.list(expr)[-1]
              file <- if (!is.null(args$file)) args$file else if (length(args)) args[[1]] else ""
              hazard <- !(is.character(file) && nzchar(file))
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
      orig(code = code, `_intent` = `_intent`)
    }
  })
  tool
}
