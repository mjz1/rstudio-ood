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
    module purge
    SINGULARITYENV_R_LIBS_USER="$libs" singularity exec \
        -B "/data1:/data1" \
        -B "/run/munge/,/etc/slurm/,/usr/lib64/slurm,/usr/lib64/libmunge.so.2" \
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
