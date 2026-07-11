#!/usr/bin/env bash
#
# install.sh -- set up the RStudio Server OnDemand app for the current user.
#
# The container images are a shared artifact. The R package libraries are not:
# packages are compiled per R minor version and installed into a directory you
# own. This script wires those two together and writes a config file that both
# the OnDemand form (Ruby/ERB) and the shell tooling (bash) read.
#
#   ./install.sh                        interactive, sensible defaults
#   ./install.sh --yes                  non-interactive, accept all defaults
#   ./install.sh --r-libs-root ~/Rlibs --image-dir /shared/images/rstudio
#   ./install.sh --dry-run              show what would happen, change nothing
#
# Or run it straight from the internet, no checkout needed:
#   curl -fsSL https://raw.githubusercontent.com/mjz1/openondemandapps/master/rstudio_dev/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --yes --queues componc_cpu,componc_gpu_batch
#
# Run --help for the full list.
#
set -euo pipefail

REPO="${RSTUDIO_DEV_REPO:-mjz1/openondemandapps}"
REF="${RSTUDIO_DEV_REF:-master}"

# ${BASH_SOURCE[0]} is unset when the script is piped into bash (`curl | bash`),
# which trips `set -u`; the :- default yields an empty path whose dirname is `.`,
# and the sibling-file check below then correctly routes to the bootstrap.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo /nonexistent)"

# Self-bootstrap. When run without a repo checkout -- the `curl ... | bash` path,
# where BASH_SOURCE is a pipe and the sibling files are not on disk -- fetch the
# repo and re-run install.sh from it. A checkout is detected by the presence of
# the sibling files this app is made of.
if [ ! -f "$SRC_DIR/sync-images.sh" ] || [ ! -f "$SRC_DIR/form.yml.erb" ]; then
    echo "Fetching rstudio_dev from github.com/${REPO} (${REF})..."
    _boot="$(mktemp -d)"
    trap 'rm -rf "$_boot"' EXIT
    if command -v git >/dev/null 2>&1; then
        git clone --quiet --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$_boot/repo" \
            || { echo "error: git clone failed" >&2; exit 1; }
    else
        curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}" | tar -xz -C "$_boot" \
            || { echo "error: download failed (need git or a reachable codeload.github.com)" >&2; exit 1; }
        mv "$_boot"/*-"${REF}" "$_boot/repo"
    fi
    # Mark the re-run so it can reject --link against this temporary checkout.
    RSTUDIO_DEV_BOOTSTRAP_TMP=1 bash "$_boot/repo/rstudio_dev/install.sh" "$@"
    exit $?
fi

# Defaults. Every one is overridable by flag, and afterwards by the config file
# or the environment at runtime.
DEF_IMAGE_DIR="/home/zatzmanm/work/images/rstudio"
DEF_R_LIBS_ROOT="$HOME/work/R/x86_64-pc-linux-gnu-library"
DEF_APP_DIR="$HOME/ondemand/dev/rstudio_dev"
DEF_CLUSTER="iris"
DEF_QUEUE="cpu"
DEF_QUEUES=""                  # empty = Queue dropdown offers just $QUEUE
DEF_SYNC_PARTITION="cpushort"
DEF_R_VERSIONS="auto"          # auto = every rstudio-<ver>.sif found in IMAGE_DIR

CONFIG_PATH="${RSTUDIO_DEV_CONFIG:-$HOME/.config/rstudio_dev/config}"

IMAGE_DIR="$DEF_IMAGE_DIR"
R_LIBS_ROOT="$DEF_R_LIBS_ROOT"
APP_DIR="$DEF_APP_DIR"
CLUSTER="$DEF_CLUSTER"
QUEUE="$DEF_QUEUE"
QUEUES="$DEF_QUEUES"
SYNC_PARTITION="$DEF_SYNC_PARTITION"
R_VERSIONS="$DEF_R_VERSIONS"
ASSUME_YES=0
DRY_RUN=0
DO_LINK=0
SHELL_INIT=""          # path to rc file, or "none"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
run()  { if (( DRY_RUN )); then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# Humanize a Slurm time limit: 7-00:00:00 -> 7d, 1-00:00:00 -> 1d, 2:00:00 -> 2h.
_humanize_time() {
    case "$1" in
        *-*)   printf '%sd' "${1%%-*}" ;;
        *:*:*) printf '%sh' "${1%%:*}" ;;
        *)     printf '%s' "$1" ;;
    esac
}

# Build a human label for a partition from Slurm: GPU types and max wall time,
# plus a use-case hint from the name. Best-effort -- if a queue already carries a
# `|label`, or Slurm is unreachable, the bare name is used unchanged. This is why
# the labels live in config (generated once here, on a login node where scontrol
# and sinfo exist) rather than in the form's ERB, which renders inside the PUN.
_queue_label() {
    local q="$1" p mt gpus gres use
    case "$q" in *"|"*) printf '%s' "$q"; return ;; esac   # already labelled
    p="$q"
    command -v scontrol >/dev/null 2>&1 || { printf '%s' "$p"; return; }
    mt="$(scontrol show partition "$p" 2>/dev/null | grep -oE 'MaxTime=[^ ]+' | cut -d= -f2)"
    [ -n "$mt" ] || { printf '%s' "$p"; return; }           # unknown partition
    if [[ "$p" == *gpu* ]]; then
        gpus="$(sinfo -h -p "$p" -o '%G' 2>/dev/null | tr ',' '\n' \
                | grep -oE 'gpu:[a-z0-9_]+' | sed 's/gpu://; s/nvidia_h200_nvl/h200/; s/nvidia_//' \
                | tr '[:lower:]' '[:upper:]' | sort -u | paste -sd/ -)"
        gres="GPU ${gpus:-?}"
    else
        gres="CPU"
    fi
    case "$p" in
        *_int)    use=' · interactive' ;;
        *_batch)  use=' · batch' ;;
        *_preem*) use=' · preemptible' ;;
        *)        use='' ;;
    esac
    # Intra-label separators must NOT be commas: commas delimit entries in
    # RSTUDIO_QUEUES, so a comma in a label would split it in the form. Use " · ".
    printf '%s|%s — %s · <=%s%s' "$p" "$p" "$gres" "$(_humanize_time "$mt")" "$use"
}

# Expand a comma-separated queue list into `partition|label` entries.
_enrich_queues() {
    local list="$1" out="" q
    local IFS=','
    for q in $list; do
        q="${q#"${q%%[![:space:]]*}"}"; q="${q%"${q##*[![:space:]]}"}"  # trim
        [ -z "$q" ] && continue
        out+="${out:+,}$(_queue_label "$q")"
    done
    printf '%s' "$out"
}

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --image-dir PATH        Where the .sif images live (shared, read-only is fine)
                          default: $DEF_IMAGE_DIR
  --r-libs-root PATH      Root of YOUR R package libraries. One subdirectory per
                          R minor version, named <ver>_singularity.
                          default: $DEF_R_LIBS_ROOT
  --r-versions "A B C"    R minor versions to set up libraries for.
                          default: auto (every image found in --image-dir)
  --app-dir PATH          Where to install the OnDemand app
                          default: $DEF_APP_DIR
  --cluster NAME          OnDemand cluster id (see /etc/ood/config/clusters.d)
                          default: $DEF_CLUSTER
  --queue NAME            Default Slurm partition, pre-selected in the form
                          default: $DEF_QUEUE
  --queues "A,B,C"        Comma-separated partitions to offer in the Queue
                          dropdown, including GPU ones (e.g.
                          componc_cpu,componc_gpu_batch). Empty = just --queue.
  --sync-partition NAME   Partition sync-images.sh submits image pulls to
                          default: $DEF_SYNC_PARTITION
  --shell-init PATH|none  rc file to add the r-wrappers.sh source line to.
                          default: ask (~/.bashrc if non-interactive)
  --link                  Symlink the app instead of copying it
  --yes, -y               Accept defaults, do not prompt
  --dry-run               Print actions without performing them
  --help, -h              This message
EOF
}

while (( $# )); do
    case "$1" in
        --image-dir)       IMAGE_DIR="$2"; shift 2 ;;
        --r-libs-root)     R_LIBS_ROOT="$2"; shift 2 ;;
        --r-versions)      R_VERSIONS="$2"; shift 2 ;;
        --app-dir)         APP_DIR="$2"; shift 2 ;;
        --cluster)         CLUSTER="$2"; shift 2 ;;
        --queue)           QUEUE="$2"; shift 2 ;;
        --queues)          QUEUES="$2"; shift 2 ;;
        --sync-partition)  SYNC_PARTITION="$2"; shift 2 ;;
        --shell-init)      SHELL_INIT="$2"; shift 2 ;;
        --link)            DO_LINK=1; shift ;;
        -y|--yes)          ASSUME_YES=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "unknown option: $1 (try --help)" ;;
    esac
done

# --link against the throwaway checkout a `curl | bash` run created would leave a
# dangling symlink once the temp dir is cleaned up. Fail fast, before the plan
# preview claims it will symlink.
if (( DO_LINK )) && [[ -n "${RSTUDIO_DEV_BOOTSTRAP_TMP:-}" ]]; then
    printf '\033[31merror:\033[0m %s\n' \
      "--link needs a persistent checkout; clone the repo and run ./install.sh --link from it" >&2
    exit 1
fi

# Interactive if not --yes and a controlling terminal is reachable. Gate on
# /dev/tty rather than `-t 0`: under `curl | bash` stdin is the pipe (so `-t 0`
# is false), but /dev/tty is still the user's terminal -- and every prompt below
# already reads from it.
interactive() {
    (( ASSUME_YES )) && return 1
    [[ -e /dev/tty ]] && (exec </dev/tty) 2>/dev/null
}

ask() {  # ask <prompt> <default> -> echoes answer
    local prompt="$1" default="$2" reply
    if ! interactive; then printf '%s' "$default"; return; fi
    read -r -p "$prompt [$default]: " reply </dev/tty
    printf '%s' "${reply:-$default}"
}

echo
echo "RStudio Server (OnDemand) -- installer"
echo "======================================"
echo

# ---------------------------------------------------------------- preflight --
command -v singularity >/dev/null 2>&1 || command -v apptainer >/dev/null 2>&1 \
    || die "neither singularity nor apptainer is on PATH"

if interactive; then
    IMAGE_DIR=$(ask "Image directory (shared)" "$IMAGE_DIR")
    R_LIBS_ROOT=$(ask "Your R package library root" "$R_LIBS_ROOT")
    CLUSTER=$(ask "OnDemand cluster id" "$CLUSTER")
    QUEUE=$(ask "Default Slurm partition" "$QUEUE")
fi

IMAGE_DIR="${IMAGE_DIR/#\~/$HOME}"
R_LIBS_ROOT="${R_LIBS_ROOT/#\~/$HOME}"
APP_DIR="${APP_DIR/#\~/$HOME}"

[[ -d $IMAGE_DIR ]] || die "image directory does not exist: $IMAGE_DIR"
[[ -r $IMAGE_DIR ]] || die "image directory is not readable: $IMAGE_DIR"

# Discover images. Only rstudio-<minor>.sif is recognised -- a legacy tag-named
# image like rstudio-v2.0.sif does not state which R it carries, and guessing is
# how you end up offering R 4.4 under a 4.5 label.
mapfile -t FOUND < <(find "$IMAGE_DIR" -maxdepth 1 -name 'rstudio-*.sif' -printf '%f\n' 2>/dev/null \
    | sed -nE 's/^rstudio-([0-9]+\.[0-9]+)\.sif$/\1/p' | sort -V)

if (( ${#FOUND[@]} == 0 )); then
    warn "no rstudio-<version>.sif images found in $IMAGE_DIR"
    warn "after install, populate it with:  $APP_DIR/sync-images.sh --sync"
fi

if [[ $R_VERSIONS == auto ]]; then
    if (( ${#FOUND[@]} )); then
        R_VERSIONS="${FOUND[*]}"
    else
        R_VERSIONS="4.3 4.4 4.5 4.6"
    fi
fi
read -r -a VERSIONS <<<"$R_VERSIONS"

echo "Plan"
echo "----"
info "images         $IMAGE_DIR  (${#FOUND[@]} found: ${FOUND[*]:-none})"
# Enrich the queue list with Slurm-derived labels (GPU types, wall-time limits)
# now, on this login node. The form just displays them.
QUEUES_OUT="$(_enrich_queues "${QUEUES:-$QUEUE}")"

info "R libraries    $R_LIBS_ROOT"
info "R versions     ${VERSIONS[*]}"
info "app            $APP_DIR  $( ((DO_LINK)) && echo '(symlink)' || echo '(copy)')"
info "config         $CONFIG_PATH"
info "cluster/queue  $CLUSTER / $QUEUE"
if [ -n "$QUEUES_OUT" ]; then
    info "queues:"
    printf '%s\n' "$QUEUES_OUT" | tr ',' '\n' | sed 's/^/                 /'
fi
echo

if interactive; then
    read -r -p "Proceed? [Y/n]: " ok </dev/tty
    [[ -z ${ok:-} || $ok =~ ^[Yy] ]] || { echo "aborted."; exit 0; }
    echo
fi

# ------------------------------------------------------------ R libraries --
echo "R package libraries"
echo "-------------------"
for v in "${VERSIONS[@]}"; do
    lib="$R_LIBS_ROOT/${v}_singularity"
    if [[ -d $lib ]]; then
        n=$(find "$lib" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
        info "exists   $lib ($n packages)"
    else
        info "create   $lib"
        run "mkdir -p '$lib'"
    fi
    # A version whose image is missing is fine -- the form simply will not offer
    # it -- but say so, because it is otherwise a silent no-op.
    [[ -e $IMAGE_DIR/rstudio-$v.sif ]] || warn "R $v has a library but no image; it will not appear in the form"
done
echo

# --------------------------------------------------------------- app files --
echo "Application"
echo "-----------"
if [[ "$(readlink -f "$SRC_DIR")" == "$(readlink -f "$APP_DIR" 2>/dev/null)" ]]; then
    info "already installed in place ($APP_DIR)"
elif (( DO_LINK )); then
    info "symlink  $APP_DIR -> $SRC_DIR"
    run "mkdir -p '$(dirname "$APP_DIR")'"
    run "ln -sfn '$SRC_DIR' '$APP_DIR'"
else
    info "copy     $SRC_DIR -> $APP_DIR"
    run "mkdir -p '$APP_DIR'"
    run "cp -r '$SRC_DIR/.' '$APP_DIR/'"
fi
run "chmod +x '$APP_DIR/sync-images.sh' 2>/dev/null || true"
echo

# ------------------------------------------------------------------ config --
echo "Configuration"
echo "-------------"
info "write    $CONFIG_PATH"
if (( DRY_RUN )); then
    echo "  [dry-run] contents:"
    sed 's/^/    | /' <<EOF
RSTUDIO_IMAGE_DIR=$IMAGE_DIR
R_LIBS_ROOT=$R_LIBS_ROOT
RSTUDIO_VERSIONS=${VERSIONS[*]}
RSTUDIO_CLUSTER=$CLUSTER
RSTUDIO_QUEUE=$QUEUE
RSTUDIO_QUEUES=$QUEUES_OUT
RSTUDIO_SYNC_PARTITION=$SYNC_PARTITION
EOF
else
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat >"$CONFIG_PATH" <<EOF
# Written by rstudio_dev/install.sh on $(date -Iseconds)
#
# Read by the OnDemand form (form.yml.erb), the job script (script.sh.erb),
# sync-images.sh, and r-wrappers.sh. Environment variables take precedence over
# anything set here. Absolute paths only; no shell expansion is performed.

# Container images. Shared; read-only access is sufficient unless you sync.
RSTUDIO_IMAGE_DIR=$IMAGE_DIR

# Your R package libraries: one <ver>_singularity subdirectory per R minor
# version. NOT shareable between users.
R_LIBS_ROOT=$R_LIBS_ROOT

# R minor versions to track when syncing images.
RSTUDIO_VERSIONS=${VERSIONS[*]}

# OnDemand cluster id, and the default Slurm partition for sessions.
RSTUDIO_CLUSTER=$CLUSTER
RSTUDIO_QUEUE=$QUEUE

# Comma-separated partitions offered in the Queue dropdown, including GPU-capable
# ones (e.g. componc_cpu,componc_gpu_batch,componc_gpu_int). GPU partitions are
# account-specific, so set them to what your account may submit to. Empty =
# offer only RSTUDIO_QUEUE.
RSTUDIO_QUEUES=$QUEUES_OUT

# Partition that sync-images.sh submits image pulls to. The pull is ~4 GB plus a
# squashfs build, so it does not belong on a login node.
RSTUDIO_SYNC_PARTITION=$SYNC_PARTITION
EOF
    chmod 0644 "$CONFIG_PATH"
fi
echo

# -------------------------------------------------------------- shell init --
echo "Shell wrappers"
echo "--------------"
SRC_LINE="source \"$APP_DIR/r-wrappers.sh\""
if [[ -z $SHELL_INIT ]]; then
    if interactive; then
        SHELL_INIT=$(ask "Add r-wrappers.sh to which rc file? ('none' to skip)" "$HOME/.bashrc")
    else
        SHELL_INIT="$HOME/.bashrc"
    fi
fi
SHELL_INIT="${SHELL_INIT/#\~/$HOME}"

if [[ $SHELL_INIT == none ]]; then
    info "skipped. Add this yourself to get R_ / Rscript_ / bash_ / sync_images:"
    info "    $SRC_LINE"
elif [[ -f $SHELL_INIT ]] && grep -qF "r-wrappers.sh" "$SHELL_INIT" 2>/dev/null; then
    info "already sourced in $SHELL_INIT"
else
    info "append   $SHELL_INIT"
    if (( DRY_RUN )); then
        printf '  [dry-run] would append:\n    | # rstudio_dev\n    | %s\n' "$SRC_LINE"
    else
        printf '\n# rstudio_dev -- R/RStudio singularity wrappers\n%s\n' "$SRC_LINE" >>"$SHELL_INIT"
    fi
fi
echo

# ----------------------------------------------------------------- summary --
echo "Done."
echo
echo "Next steps"
echo "----------"
if (( ${#FOUND[@]} == 0 )); then
    echo "  1. Pull images:      $APP_DIR/sync-images.sh --sync"
else
    echo "  1. Check images:     $APP_DIR/sync-images.sh"
fi
echo "  2. Reload your shell: source ${SHELL_INIT/none/$HOME/.bashrc}"
echo "  3. Open the app in OnDemand (Interactive Apps -> RStudio Server)"
echo
echo "Your R libraries start empty. Install packages from inside RStudio, or:"
echo "  Rscript_ -e 'install.packages(\"data.table\")'"
echo
if (( DRY_RUN )); then echo "(dry run: nothing was changed)"; fi
