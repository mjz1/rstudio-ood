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
