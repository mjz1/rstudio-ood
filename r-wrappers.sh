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

update_r() {
    echo "update_r is deprecated: it pulled by moving tag, never updated the" >&2
    echo "rstudio-latest.sif symlink, and could replace it with a 4 GB file." >&2
    echo "Forwarding to: sync-images.sh --sync $*" >&2
    "$RSTUDIO_SYNC" --sync "$@"
}
