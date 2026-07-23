# shellcheck shell=bash
# ---------------------------------------------------------------------------
# R / RStudio Singularity wrappers.
#
# Source this from ~/.alias (or ~/.bashrc):
#
#     source "$HOME/ondemand/dev/rstudio_dev/r-wrappers.sh"
#
# and delete the old inline update_r / R_ / bash_ / Rscript_ block.
#
#   R_ [VERSION] [args...]        interactive R
#   Rscript_ [-v VERSION] ...     non-interactive R (arguments ARE forwarded)
#   bash_ [-v VERSION] [args...]  shell inside the container
#   sync_images [--sync] [ver]    check for / pull newer images
#   rstudio_slots [--rm|--prune]  inspect / tidy named session slots
#   rstudio_mcp_init [DIR]        per-project setup for AI agent access (MCP)
#
# VERSION is an R minor version (e.g. 4.5) or `latest`. Omit it to get the
# newest R that has both an image and a populated package library.
#
# The images are a shared artifact; the R package libraries are per-user.
# Someone reusing this must point R_LIBS_ROOT at their own library root.
# ---------------------------------------------------------------------------

# Config file written by install.sh; environment still wins over it.
_rsd_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=conf.sh
[ -r "$_rsd_here/conf.sh" ] && . "$_rsd_here/conf.sh"

: "${RSTUDIO_IMAGE_DIR:=$HOME/work/images/rstudio}"
: "${R_LIBS_ROOT:=$HOME/work/R/x86_64-pc-linux-gnu-library}"
: "${RSTUDIO_SYNC:=$_rsd_here/sync-images.sh}"
unset _rsd_here

# `latest` tracks the newest *image*, which may be an R version whose library
# has not been populated yet. Default the wrappers to the newest R that has both
# an image and a non-empty library, so syncing a new major R can never silently
# strip the packages out from under an existing script.
_r_default_version() {
    local v
    for v in $(find "$R_LIBS_ROOT" -maxdepth 1 -name '*_singularity' -printf '%f\n' 2>/dev/null \
                 | sed 's/_singularity$//' | sort -Vr); do
        if [ -n "$(ls -A "$R_LIBS_ROOT/${v}_singularity" 2>/dev/null)" ] \
           && [ -e "$RSTUDIO_IMAGE_DIR/rstudio-${v}.sif" ]; then
            printf '%s' "$v"; return 0
        fi
    done
    printf 'latest'
}

_r_sif_path() {
    local v="$1" p="$RSTUDIO_IMAGE_DIR/rstudio-$1.sif"
    if [ ! -e "$p" ]; then
        {
            echo "Error: image not found: $p"
            echo "Available:"
            find "$RSTUDIO_IMAGE_DIR" -maxdepth 1 -name 'rstudio-*.sif' -printf '  %f\n' 2>/dev/null | sort -V
            echo "Pull it with: $RSTUDIO_SYNC --sync $v"
        } >&2
        return 1
    fi
    printf '%s' "$p"
}

# Derive the R minor version from the *resolved* image, never from the string
# the caller typed: `latest` is a symlink, so the two can disagree.
_r_minor_of_sif() {
    local base
    base=$(basename "$(readlink -f "$1")")
    base=${base#rstudio-}; base=${base%.sif}
    [[ $base =~ ([0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
}

_r_libs_of() {
    local minor="$1" lib="$R_LIBS_ROOT/${1}_singularity"
    if [ ! -d "$lib" ]; then
        # Never fall back to another version's library. Packages built for one R
        # minor are not loadable by another, and R ignores a missing
        # R_LIBS_USER silently -- so a fallback hides the problem entirely.
        echo "Error: no R package library for R $minor at $lib" >&2
        echo "Create it with: mkdir -p '$lib'" >&2
        return 1
    fi
    [ -n "$(ls -A "$lib" 2>/dev/null)" ] || echo "Warning: R $minor package library is empty: $lib" >&2
    printf '%s' "$lib"
}

_r_exec() {   # _r_exec <sif> <libs> <cmd> [args...]
    local sif="$1" libs="$2"; shift 2
    # Loaded modules can leak conflicting libraries into the container env.
    # Guarded: not every site has environment modules, and a non-login shell
    # may not have the `module` function even where the site does.
    if command -v module >/dev/null 2>&1; then module purge; fi

    # GPU passthrough. Enable --nv only when Slurm GRANTED a GPU (its gres plugin
    # sets CUDA_VISIBLE_DEVICES / SLURM_JOB_GPUS, e.g. inside `salloc
    # --gres=gpu:1`). Not a /dev/nvidia* probe: a CPU job on a GPU-capable node
    # sees those device files despite being granted no GPU, and probing them
    # would let a CPU session grab a GPU allocated to someone else. --nv binds
    # only the host driver; torch and friends bring their own CUDA toolkit.
    local nv="" cuda_env=""
    if [ -n "${CUDA_VISIBLE_DEVICES:-}" ] || [ -n "${SLURM_JOB_GPUS:-}" ] || [ -n "${GPU_DEVICE_ORDINAL:-}" ]; then
        nv="--nv"
        echo "GPU granted -> --nv" >&2
        # Pick the torch CUDA build matching this node's driver (highest
        # supported build <= nvidia-smi's max CUDA), rather than hardcoding one.
        # Exported so torch::install_torch() fetches the GPU build; the image
        # ships no CUDA toolkit, so torch would otherwise install CPU. Only the
        # driver is needed at runtime -- the build bundles the toolkit.
        local supported="${RSTUDIO_TORCH_CUDA:-12.9 12.8 12.6}" ceiling b
        ceiling="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
        if [ -n "$ceiling" ]; then
            for b in $supported; do
                if [ "$(printf '%s\n%s\n' "$b" "$ceiling" | sort -V | tail -1)" = "$ceiling" ]; then
                    cuda_env="$b"; echo "R torch -> CUDA $b (driver up to $ceiling)" >&2; break
                fi
            done
        fi
    fi

    # renv keeps its package library and cache under $XDG_CACHE_HOME/R/renv, and
    # OnDemand sessions pin XDG_CACHE_HOME to $RSTUDIO_WORK_DIR/.cache (large
    # storage). A host shell that does not export it would leave the wrappers on
    # the default ~/.cache -- a SECOND renv cache, growing to tens of GB inside
    # a quota'd home directory, disjoint from every package the sessions
    # installed. Align with the sessions; an exported value still wins, the same
    # precedence as every other setting here.
    local cache_env=""
    if [ -z "${XDG_CACHE_HOME:-}" ]; then
        cache_env="${RSTUDIO_WORK_DIR:-$HOME/work}/.cache"
        mkdir -p "$cache_env" 2>/dev/null || true
    fi

    # Host paths bound into the container come from RSTUDIO_BIND_PATHS (config),
    # not a hard-coded /data1: the storage a user's images and libraries live on
    # is site-specific, and a bind path that does not exist makes singularity
    # fail outright. _rsd_bind_args filters to what exists here.
    local -a binds=()
    # Guarded: _rsd_bind_args lives in conf.sh, and this file gets copied around
    # without its siblings. Missing conf just means no extra binds ($HOME still
    # works), not a "command not found" on every wrapper call.
    if declare -F _rsd_bind_args >/dev/null; then
        mapfile -t binds < <(_rsd_bind_args)
    fi

    # This host exports SSL_CERT_FILE/SSL_CERT_DIR pointing at /etc/pki (RHEL),
    # and Singularity forwards them into the Ubuntu container where those paths
    # do not exist. OpenSSL-based TLS then fails -- Quarto (Deno) reports
    # "Failed to load platform certificates". Remap to the container's bundle
    # rather than --cleanenv, which would also drop SLURM_* and R_LIBS_USER.
    # Conditional variables go through `env`, never a ${var:+NAME=val} prefix:
    # bash decides what is an assignment BEFORE expansion, so an assignment that
    # materialises out of ${:+} is parsed as the COMMAND ("NAME=val: No such
    # file or directory"). The old ${cuda_env:+...} form had exactly this bug --
    # invisible on CPU nodes, where it expands to nothing, fatal on GPU nodes.
    local -a extra_env=()
    [ -n "$cuda_env" ]  && extra_env+=("SINGULARITYENV_CUDA=$cuda_env")
    [ -n "$cache_env" ] && extra_env+=("SINGULARITYENV_XDG_CACHE_HOME=$cache_env")

    SINGULARITYENV_R_LIBS_USER="$libs" \
    SINGULARITYENV_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SINGULARITYENV_SSL_CERT_DIR=/etc/ssl/certs \
    env "${extra_env[@]}" \
    "${RSTUDIO_SINGULARITY:-singularity}" exec ${nv} \
        "${binds[@]}" \
        -B "$HOME:$HOME" \
        "$sif" \
        bash -c 'echo "slurm:x:300:300::/opt/slurm/slurm:/bin/false" >> /etc/passwd 2>/dev/null || true
                 exec "$@"' _ "$@"
}

# Echo "<sif>\t<libs>" for an optional `-v VERSION` prefix.
_r_resolve() {
    local ver sif libs
    if [ "${1:-}" = "-v" ]; then ver="$2"; else ver="$(_r_default_version)"; fi
    sif=$(_r_sif_path "$ver") || return 1
    libs=$(_r_libs_of "$(_r_minor_of_sif "$sif")") || return 1
    printf '%s\t%s' "$sif" "$libs"
}

R_() {
    local ver sif libs
    # Back-compat: `R_ 4.5` / `R_ latest` still work as a bare positional.
    if [[ ${1:-} =~ ^(latest|v?\.?[0-9]+(\.[0-9]+)*)$ ]]; then ver="$1"; shift
    elif [ "${1:-}" = "-v" ]; then ver="$2"; shift 2
    else ver="$(_r_default_version)"; fi

    sif=$(_r_sif_path "$ver") || return 1
    libs=$(_r_libs_of "$(_r_minor_of_sif "$sif")") || return 1
    echo "Image:       $(basename "$(readlink -f "$sif")")" >&2
    echo "R_LIBS_USER: $libs" >&2
    _r_exec "$sif" "$libs" R "$@"
}

Rscript_() {
    local sif libs r
    if [ "${1:-}" = "-v" ]; then r=$(_r_resolve -v "$2") || return 1; shift 2
    else r=$(_r_resolve) || return 1; fi
    IFS=$'\t' read -r sif libs <<<"$r"
    # The previous version ended in `bash -c '... && Rscript'` and dropped every
    # argument, so `Rscript_ foo.R` ran a bare Rscript.
    _r_exec "$sif" "$libs" Rscript "$@"
}

bash_() {
    local sif libs r
    if [ "${1:-}" = "-v" ]; then r=$(_r_resolve -v "$2") || return 1; shift 2
    else r=$(_r_resolve) || return 1; fi
    IFS=$'\t' read -r sif libs <<<"$r"
    _r_exec "$sif" "$libs" bash "$@"
}

sync_images() { "$RSTUDIO_SYNC" "$@"; }

# rstudio_slots [--rm SLOT|--prune] -- inspect and tidy named session slots.
#
# Slots are just directories: <work>/.rstudio-sessions/<slot>. They hold RStudio
# state (open tabs, history, per-project state) and anything the session wrote to
# XDG_DATA_HOME. Removing one is a clean reset of that named session; the next
# launch recreates it empty. Nothing here touches your R libraries or the shared
# renv cache -- packages are never at risk.
rstudio_slots() {
    local root="${RSTUDIO_WORK_DIR:-$HOME/work}/.rstudio-sessions"
    [ -d "$root" ] || { echo "no slots yet ($root)"; return 0; }

    local running=""
    command -v squeue >/dev/null 2>&1 && \
        running="$(squeue -h -u "$USER" -o '%j' 2>/dev/null | sed -n 's/^rstudio-//p')"
    _is_running() { printf '%s\n' "$running" | grep -qx -- "$1"; }

    case "${1:-list}" in
        --rm)
            local s="${2:?usage: rstudio_slots --rm SLOT}"
            [ -d "$root/$s" ] || { echo "no such slot: $s" >&2; return 1; }
            if _is_running "$s"; then
                echo "refusing: slot '$s' has a running session -- delete it in OnDemand first" >&2
                return 1
            fi
            rm -rf "${root:?}/${s:?}"
            echo "removed slot '$s' (next launch starts it fresh)"
            ;;
        --prune)
            # Slots untouched for 30+ days and not running.
            local s n=0
            for d in "$root"/*/; do
                [ -d "$d" ] || continue
                s="$(basename "$d")"
                _is_running "$s" && continue
                if [ -z "$(find "$d" -maxdepth 0 -mtime -30 2>/dev/null)" ]; then
                    rm -rf "$d"; echo "pruned '$s' (idle 30+ days)"; n=$((n+1))
                fi
            done
            [ "$n" -eq 0 ] && echo "nothing to prune (no slot idle 30+ days)"
            ;;
        list|"")
            printf '  %-16s %8s  %-14s %s\n' SLOT SIZE 'LAST USED' STATUS
            for d in "$root"/*/; do
                [ -d "$d" ] || continue
                local s sz age st
                s="$(basename "$d")"
                sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
                age="$(find "$d" -maxdepth 0 -printf '%TY-%Tm-%Td' 2>/dev/null)"
                if _is_running "$s"; then st="running now"; else st="-"; fi
                printf '  %-16s %8s  %-14s %s\n' "$s" "$sz" "$age" "$st"
            done
            echo
            echo "  rstudio_slots --rm SLOT   reset one slot (fresh on next launch)"
            echo "  rstudio_slots --prune     remove slots idle 30+ days"
            ;;
        *) echo "usage: rstudio_slots [--rm SLOT | --prune]" >&2; return 1 ;;
    esac
    unset -f _is_running
}

# rstudio_mcp_init [DIR] -- one-time per-project setup for AI agent access.
#
# Writes DIR/.mcp.json (default: the current directory) registering an
# "r-session" MCP server for agents launched there. Claude Code reads .mcp.json
# natively; the file is plain JSON and committable, so a lab member cloning the
# project inherits the server. It is deliberately generic: WHICH tools it
# serves comes from RSTUDIO_MCP_TOOLS, which the session exports per the launch
# form's "AI agent access" choice -- so the file never needs rewriting, and the
# form stays in control per session. Outside a session (variable unset) it
# serves a harmless read-only default; the execute tool (run_r) additionally
# needs BTW_RUN_R_ENABLED, which only an execute-mode session exports.
#
# --no-init-file is LOAD-BEARING, and not an optimisation. A stdio MCP server
# speaks JSON-RPC over stdout, so ANY R startup chatter on stdout corrupts the
# protocol -- the client reads a package banner where it expected a handshake
# and the server never connects. Project .Rprofile files are full of such
# chatter, and renv is the worst case: on a large project its startup sync
# check prints "NOTE: Dependency discovery took N seconds..." to stdout AND
# takes 20+ seconds doing it, blowing the client's 30s connect timeout as well
# (measured: 32.3s startup, 77k files -- two independent fatal failures).
# Skipping the profile closes the whole class rather than muting one source.
#
# It costs nothing, because the server does not need the project: it defines
# tools and dials the session's socket. The tools EXECUTE in the R session,
# which has renv fully loaded. mcptools/btw still resolve because renv exports
# R_LIBS_USER (the project library) to child processes -- and outside renv,
# R_LIBS_USER is the session's per-version library. If a project somehow needs
# its profile, the narrower fix is an "env" block with
# RENV_CONFIG_SYNCHRONIZED_CHECK=FALSE instead.
#
# The server command sources RSTUDIO_MCP_GUARD (template/mcp-guard.R, exported
# by an execute-mode session) to wrap run_r with the AST gate that refuses
# session-wedging calls -- see that file and issue #2. Both are read from the
# ENVIRONMENT, never baked in: the same committed .mcp.json then works for
# every user and every app version, and the launch form stays in control of
# what a session actually exposes. GUARD unset means no wrapping (a read-only
# session exports none and has no run_r to guard) -- but set-and-MISSING is a
# broken deploy, and the command stop()s rather than silently serving an
# unguarded run_r; the error lands on stderr, which is safe for a stdio MCP
# server (only stdout carries JSON-RPC). RSTUDIO_MCP_TOOLS set-but-EMPTY falls
# back to the read default in R, deliberately: Sys.getenv()'s fallback applies
# only when a variable is UNSET, and btw_tools() with no names serves btw's
# ENTIRE default set -- files/git/web tools included.

# The one and only copy of the server entries: printed for paste-by-hand and
# embedded by the write path below, so the two can never drift. TWO servers,
# deliberately: once the primary (r-session) connects to a session, mcptools
# forwards EVERY tool call there -- so a status tool it served would queue
# behind the very wedge it diagnoses. r-session-status runs with
# session_tools = FALSE (tools execute in its own process) and reads /proc,
# which works precisely when the session is unresponsive.
_rstudio_mcp_entries() {
    cat <<'ENTRY'
    "r-session": {
      "command": "Rscript",
      "args": [
        "--no-init-file",
        "-e",
        "local({ tl <- Sys.getenv('RSTUDIO_MCP_TOOLS'); if (!nzchar(tl)) tl <- 'env,docs,sessioninfo'; t <- do.call(btw::btw_tools, as.list(Filter(nzchar, strsplit(tl, ',')[[1]]))); g <- Sys.getenv('RSTUDIO_MCP_GUARD'); if (nzchar(g)) { if (!file.exists(g)) stop('RSTUDIO_MCP_GUARD is set but the file is missing (broken deploy?): ', g); source(g, local = TRUE); t <- guard_btw_tools(t) }; mcptools::mcp_server(tools = t) })"
      ]
    },
    "r-session-status": {
      "command": "Rscript",
      "args": [
        "--no-init-file",
        "-e",
        "local({ g <- Sys.getenv('RSTUDIO_MCP_GUARD'); if (!nzchar(g)) stop('not inside an agent-enabled RStudio session (RSTUDIO_MCP_GUARD unset)'); if (!file.exists(g)) stop('RSTUDIO_MCP_GUARD is set but the file is missing (broken deploy?): ', g); source(g, local = TRUE); mcptools::mcp_server(tools = list(rstudio_session_status()), session_tools = FALSE) })"
      ]
    }
ENTRY
}

rstudio_mcp_init() {
    local dir="${1:-.}" f
    [ -d "$dir" ] || { echo "no such directory: $dir" >&2; return 1; }
    f="$dir/.mcp.json"
    if [ -e "$f" ]; then
        if grep -q '"r-session"' "$f" 2>/dev/null; then
            # "Has an r-session server" is not "has the CURRENT one". A file
            # written before the guard existed serves an UNGUARDED run_r
            # forever -- and .mcp.json is committable, so a stale copy
            # propagates to everyone who clones the project. Detect the guard
            # by its function name and say exactly what to do.
            if grep -q 'guard_btw_tools' "$f" 2>/dev/null &&
               grep -q '"r-session-status"' "$f" 2>/dev/null; then
                echo "already configured: $f (r-session + status servers, run_r guard wired)"
                # Re-running an idempotent command usually means "it isn't
                # working". The two answers are both restarts (see below), so
                # say them here rather than only on the write path -- this is
                # the moment the user is actually looking.
                echo "  not seeing your session? both halves are read only at STARTUP:"
                echo "  restart R if mcptools was installed after the session began,"
                echo "  and restart the agent if it was running before this file existed."
                return 0
            fi
            {
                echo "$f has an \"r-session\" server from an OLDER app version"
                echo "(missing the run_r deadlock guard and/or the session-status server)."
                echo "Replace the \"r-session\" entry with BOTH of:"
                _rstudio_mcp_entries
            } >&2
            return 1
        fi
        # Never rewrite a file another tool owns half of: merging JSON in bash
        # is how files get corrupted. Print the EXACT entry to paste instead --
        # a "see the source" pointer here is useless at the moment it appears.
        {
            echo "refusing to modify existing $f -- paste this into its \"mcpServers\" object:"
            _rstudio_mcp_entries
        } >&2
        return 1
    fi
    {
        echo '{'
        echo '  "mcpServers": {'
        _rstudio_mcp_entries
        echo '  }'
        echo '}'
    } > "$f"
    echo "wrote $f"
    # Both halves of the setup are read exactly ONCE, at startup: the session
    # registers with mcptools from its rstudio.sessionInit hook, and the agent
    # reads .mcp.json when it launches. So installing the packages into an
    # already-running session, or writing this file beside an already-running
    # agent, changes nothing until each is restarted -- and NEITHER failure
    # announces itself: an MCP server that finds no session to connect to
    # answers from its own empty process instead of erroring. Spelling out the
    # restarts costs three lines here and saves the silent-empty-environment
    # debugging session that first-time setup otherwise produces.
    if [ -z "${RSTUDIO_MCP_ACCESS:-}" ]; then
        echo "  NOTE: this shell is not inside an agent-enabled session -- launch one with"
        echo "        'AI agent access' set on the form (the file is ready for it)."
    fi
    echo "  1. install the R packages into this project's library:  install.packages(c('mcptools','btw'))"
    echo "  2. if you installed them just now, restart R (Session > Restart R): the session"
    echo "     registers with mcptools only at startup, so it is NOT registered yet. You are"
    echo "     registered once the console prints '-- MCP: agents in this session's terminal ... --'"
    echo "  3. run your agent (claude, copilot) from this directory in the session's Terminal."
    echo "     An agent that was ALREADY running has not read this file -- restart it too."
}

update_r() {
    echo "update_r is deprecated: it pulled by moving tag, never updated the" >&2
    echo "rstudio-latest.sif symlink, and could replace it with a 4 GB file." >&2
    echo "Forwarding to: sync-images.sh --sync $*" >&2
    "$RSTUDIO_SYNC" --sync "$@"
}
