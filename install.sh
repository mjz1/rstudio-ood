#!/usr/bin/env bash
#
# install.sh -- set up the RStudio Server OnDemand app for the current user.
#
# Nothing in here is specific to any one person or lab. Every path, partition and
# cluster id is either asked for, or discovered from this machine (Slurm's
# partition ACLs, the mount table, the images already on disk). The script's job
# is to make those choices explicit -- especially the three directories that grow
# to tens of gigabytes and therefore must not sit in a quota'd home directory --
# and record them in a config file that every other piece of the app reads.
#
#   ./install.sh                        interactive interview (recommended)
#   ./install.sh --yes                  non-interactive, discovered defaults
#   ./install.sh --dry-run              show what would happen, change nothing
#   ./install.sh --image-dir /data1/lab/shared/rstudio --no-sync
#
# Or run it straight from the internet, no checkout needed:
#   curl -fsSL https://raw.githubusercontent.com/mjz1/openondemandapps/master/rstudio_dev/install.sh | bash
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

CONFIG_PATH="${RSTUDIO_DEV_CONFIG:-$HOME/.config/rstudio_dev/config}"

# Rough sizes, quoted in the interview so the storage choices are informed rather
# than guessed at. They are the reason the big directories must not land in $HOME.
SZ_IMAGES="~2 GB per R version, doubled while the previous build is retained (~16-32 GB for four)"
SZ_RLIBS="grows with what you install; libtorch alone is ~6 GB per R version"
SZ_WORK="renv package cache, session state and the container pull cache; tens of GB in practice"

# Everything below is a *starting point* for the interview or for --yes, not a
# baked-in choice. Storage paths are discovered (see pick_storage_root), Slurm
# partitions come from this cluster's ACLs, the cluster id from Slurm itself.
APP_DIR="$HOME/ondemand/dev/rstudio_dev"
IMAGE_DIR=""
R_LIBS_ROOT=""
WORK_DIR=""
STORAGE_ROOT=""
BIND_PATHS=""
CLUSTER=""
QUEUE=""
QUEUES=""
SYNC_PARTITION=""
R_VERSIONS="auto"          # auto = every rstudio-<ver>.sif found in IMAGE_DIR
SYNC_ROLE=""               # maintainer (pulls images) | consumer (reads someone else's)
SHARE_IMAGES=""            # yes = chmod g+rx the image dir so labmates can read it
SHELL_INIT=""              # path to rc file, or "none"
ASSUME_YES=0
DRY_RUN=0
DO_LINK=0
CONTAINER_CMD=""

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
head2(){ printf '\n%s\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' -)"; }
# say/note write to STDERR so they can be used inside functions whose stdout is
# captured by a command substitution (the interview helpers below).
say()  { printf '  %s\n' "$*" >&2; }
blank(){ printf '\n' >&2; }

dry() { (( DRY_RUN )); }
do_mkdir() { if dry; then info "[dry-run] mkdir -p $1"; else mkdir -p "$1"; fi; }

# ---------------------------------------------------------------- interaction --

# Interactive if not --yes and a controlling terminal is reachable. Gate on
# /dev/tty rather than `-t 0`: under `curl | bash` stdin is the pipe (so `-t 0`
# is false), but /dev/tty is still the user's terminal -- and every prompt below
# already reads from it.
interactive() {
    (( ASSUME_YES )) && return 1
    [[ -e /dev/tty ]] && (exec </dev/tty) 2>/dev/null
}

ask() {  # ask <prompt> <default> -> echoes answer on stdout
    local prompt="$1" default="$2" reply
    if ! interactive; then printf '%s' "$default"; return; fi
    read -r -p "  $prompt [$default]: " reply </dev/tty
    printf '%s' "${reply:-$default}"
}

confirm() {  # confirm <prompt> <Y|N default> -> exit status
    local prompt="$1" default="${2:-Y}" reply
    if ! interactive; then [[ $default == [Yy] ]]; return; fi
    local hint='[Y/n]'; [[ $default == [Yy] ]] || hint='[y/N]'
    read -r -p "  $prompt $hint: " reply </dev/tty
    reply="${reply:-$default}"
    [[ $reply =~ ^[Yy] ]]
}

# ------------------------------------------------------------------- storage --

# Size/quota questions must be asked about a path that may not exist yet, so walk
# up to the nearest ancestor that does.
_nearest_existing() {
    local p="${1:-/}"
    while [[ ! -e $p && $p != / ]]; do p="$(dirname "$p")"; done
    printf '%s' "$p"
}
# `stat -c %m` walks the path it is GIVEN and does not follow symlinks, so it
# reports /home for ~/work even when that is a symlink onto large storage --
# which is the single most common way to have a perfectly good storage root.
# Resolve first, then ask.
_fs_of()    { stat -c '%m' "$(readlink -f "$(_nearest_existing "$1")")" 2>/dev/null || printf '?'; }
_avail_of() { df -Ph "$(_nearest_existing "$1")" 2>/dev/null | awk 'NR==2{print $4}'; }
_total_of() { df -Ph "$(_nearest_existing "$1")" 2>/dev/null | awk 'NR==2{print $2}'; }

# Is this path on the same filesystem as $HOME? That -- not a string prefix -- is
# the question that matters: `~/work` is often a symlink to large storage and is
# perfectly fine, while a literal path under a home filesystem is not.
on_home_fs() { [[ "$(_fs_of "$1")" == "$(_fs_of "$HOME")" ]]; }

# Large storage, discovered rather than assumed. Anything that is (a) reachable
# and (b) not on the home filesystem qualifies; the first hit wins, and $HOME is
# the reluctant fallback.
pick_storage_root() {
    local c
    for c in "${RSTUDIO_WORK_DIR:-}" "$HOME/work" "$HOME/scratch" "${SCRATCH:-}" \
             "/scratch/$USER" /data1/*/users/"$USER" /data/*/users/"$USER"; do
        [[ -n $c && -d $c ]] || continue
        on_home_fs "$c" && continue
        printf '%s' "$(readlink -f "$c")"; return 0
    done
    printf '%s' "$HOME"
}

# Prompt for a directory that will get big, explaining what lands there and how
# much it costs, and pushing back if the answer is on the home filesystem.
ask_big_dir() {  # ask_big_dir <label> <what-grows-here> <prompt> <default>
    local label="$1" grows="$2" prompt="$3" default="$4" ans
    blank
    say "$label"
    say "  $grows"
    while :; do
        ans="$(ask "$prompt" "$default")"
        ans="${ans/#\~/$HOME}"
        [[ $ans == /* ]] || { say "  Please give an absolute path."; continue; }
        if on_home_fs "$ans"; then
            blank
            warn "$ans is on your HOME filesystem ($(_fs_of "$ans"): $(_avail_of "$ans") free of $(_total_of "$ans"))."
            warn "Home directories are usually quota'd and shared; filling one up breaks logins,"
            warn "and this directory $grows"
            if interactive; then
                confirm "Use it anyway?" N || continue
            else
                warn "continuing anyway (--yes); pass --storage-root to put this on large storage"
            fi
        else
            say "  -> $(_fs_of "$ans"): $(_avail_of "$ans") free of $(_total_of "$ans")"
        fi
        printf '%s' "$ans"; return 0
    done
}

# Which ancestors of a path deny group traversal? Sharing images with a labmate
# needs g+x on every directory above them, not just on the image dir itself --
# the usual reason "I chmod'd it and they still cannot read it".
group_blocked_ancestors() {
    local p; p="$(readlink -f "$1")"
    local out=""
    while [[ $p != / && -n $p ]]; do
        [[ -d $p ]] && [[ "$(stat -c '%A' "$p" 2>/dev/null | cut -c5-7)" != *x* ]] && out+="$p"$'\n'
        p="$(dirname "$p")"
    done
    printf '%s' "$out"
}

# --------------------------------------------------------------------- slurm --

_humanize_time() {   # 7-00:00:00 -> 7d, 02:00:00 -> 2h
    case "$1" in
        *-*)   printf '%sd' "$(( 10#${1%%-*} ))" ;;
        *:*:*) printf '%sh' "$(( 10#${1%%:*} ))" ;;
        *)     printf '%s' "$1" ;;
    esac
}
_time_seconds() {    # for ranking partitions by wall-clock limit
    local t="$1" d=0 h=0 m=0 s=0
    case "$t" in
        UNLIMITED|unlimited) printf '999999999'; return ;;
        *-*) d="${t%%-*}"; t="${t#*-}" ;;
    esac
    IFS=: read -r h m s <<<"$t"
    printf '%s' $(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}

PARTINFO=""      # cache of `scontrol show partition -o`
MY_ACCOUNTS=""
MY_GROUPS=""

_slurm_probe() {
    command -v scontrol >/dev/null 2>&1 || return 1
    PARTINFO="$(scontrol show partition -o 2>/dev/null)" || return 1
    [[ -n $PARTINFO ]] || return 1
    MY_ACCOUNTS="$(sacctmgr -nP show assoc user="$USER" format=account 2>/dev/null | cut -d'|' -f1 | sort -u | tr '\n' ' ')"
    MY_GROUPS="$(id -nG 2>/dev/null)"
    return 0
}

_in_csv() {  # _in_csv "<space list>" "<csv list>"  -> true if any of $1 is in $2
    local needle
    for needle in $1; do
        case ",$2," in *",$needle,"*) return 0 ;; esac
    done
    return 1
}

# Partitions THIS user may actually submit to. Slurm publishes the ACLs
# (AllowAccounts / DenyAccounts / AllowGroups); combined with the user's
# associations they say exactly what is usable. This is what makes the app
# portable to another lab -- or another cluster -- without editing any list:
# nothing is hard-coded, and a partition the user cannot use is never offered.
# (On this cluster the shared `cpu` and `gpu` partitions deny most lab accounts,
# so a hard-coded default of "cpu" would have been unsubmittable for many users.)
allowed_partitions() {   # -> "<name> <maxtime> <state>" per line
    local line p aa da ag st mt
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        p="$(grep -oE '^PartitionName=[^ ]+' <<<"$line" | cut -d= -f2)"
        [[ -n $p ]] || continue
        st="$(grep -oE ' State=[^ ]+' <<<"$line" | cut -d= -f2)"
        [[ $st == UP ]] || continue
        mt="$(grep -oE ' MaxTime=[^ ]+' <<<"$line" | cut -d= -f2)"
        aa="$(grep -oE ' AllowAccounts=[^ ]+' <<<"$line" | cut -d= -f2)"
        da="$(grep -oE ' DenyAccounts=[^ ]+' <<<"$line" | cut -d= -f2)"
        ag="$(grep -oE ' AllowGroups=[^ ]+' <<<"$line" | cut -d= -f2)"
        # No associations reported (no sacctmgr, or a site that does not use
        # accounts): fall back to offering everything that is UP, rather than
        # silently offering nothing.
        if [[ -n $MY_ACCOUNTS ]]; then
            [[ -n $aa && $aa != ALL ]] && { _in_csv "$MY_ACCOUNTS" "$aa" || continue; }
            [[ -n $da && $da != "(null)" ]] && { _in_csv "$MY_ACCOUNTS" "$da" && continue; }
        fi
        [[ -n $ag && $ag != ALL ]] && { _in_csv "$MY_GROUPS" "$ag" || continue; }
        printf '%s %s\n' "$p" "${mt:-UNLIMITED}"
    done <<<"$PARTINFO"
}

_partition_gpus() {  # GPU types a partition offers, e.g. "H100/H200"
    sinfo -h -p "$1" -o '%G' 2>/dev/null | tr ',' '\n' \
        | grep -oE 'gpu:[a-z0-9_]+' | sed 's/gpu://; s/nvidia_h200_nvl/h200/; s/nvidia_//' \
        | tr '[:lower:]' '[:upper:]' | sort -u | paste -sd/ -
}

# Is this a GPU partition? NOT "do any of its nodes have a GPU" -- GPU nodes also
# belong to CPU partitions (here, cpushort has 34 GPU nodes among 235), so that
# test calls every partition a GPU partition. It is also not the name: a site can
# call them anything. The measurable property is that EVERY node in the partition
# offers a GPU, which is what makes `--gres=gpu:N` reliably schedulable there.
_is_gpu_partition() {
    # IFS is reset explicitly: bash's `local` is dynamically scoped, so a caller
    # that splits on commas (see _enrich_queues) would otherwise leak IFS=','
    # into this `read` and land both fields in $total.
    local counts total gpu IFS=$' \t\n'
    counts="$(sinfo -h -p "$1" -o '%D %G' 2>/dev/null \
        | awk '{tot+=$1; if ($2 ~ /gpu:/) g+=$1} END{printf "%d %d", tot, g+0}')"
    read -r total gpu <<<"$counts"
    (( total > 0 && gpu == total ))
}

# Build the human label the Queue dropdown shows. Generated here, on a login node
# where scontrol and sinfo exist, because the form renders inside the PUN where
# they may not. Intra-label separators must NOT be commas: commas delimit entries
# in RSTUDIO_QUEUES, so a comma inside a label would split it in the form.
_queue_label() {
    local q="$1" mt gpus gres use
    case "$q" in *"|"*) printf '%s' "$q"; return ;; esac   # already labelled
    mt="$(awk -v p="$q" '$1==p{print $2}' <<<"$ALLOWED_LIST")"
    if [[ -z $mt ]]; then
        command -v scontrol >/dev/null 2>&1 \
            && mt="$(scontrol show partition "$q" 2>/dev/null | grep -oE 'MaxTime=[^ ]+' | cut -d= -f2)"
    fi
    [[ -n $mt ]] || { printf '%s' "$q"; return; }
    if _is_gpu_partition "$q"; then
        gpus="$(_partition_gpus "$q")"
        gres="GPU ${gpus:-?}"
    else
        gres="CPU"
    fi
    case "$q" in
        *_int|*interactive*) use=' · interactive' ;;
        *_batch)             use=' · batch' ;;
        *_preem*|*preempt*)  use=' · preemptible' ;;
        *short*)             use=' · short' ;;
        *)                   use='' ;;
    esac
    printf '%s|%s — %s · <=%s%s' "$q" "$q" "$gres" "$(_humanize_time "$mt")" "$use"
}

_enrich_queues() {   # comma-separated names -> comma-separated name|label entries
    local list="$1" out="" q
    # Split by rewriting the separator rather than by setting IFS=',' for the
    # body: `local IFS` is dynamically scoped and would follow _queue_label into
    # every function it calls. The `IFS=` here is a prefix assignment to `read`
    # alone, so it does not escape this loop.
    while IFS= read -r q; do
        q="${q#"${q%%[![:space:]]*}"}"; q="${q%"${q##*[![:space:]]}"}"
        [[ -z $q ]] && continue
        out+="${out:+,}$(_queue_label "$q")"
    done < <(printf '%s' "$list" | tr ',' '\n')
    printf '%s' "$out"
}

# ---------------------------------------------------------------------- flags --

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Every option below is asked for interactively when omitted. Nothing is
hard-coded to a particular user, lab, or cluster: storage is discovered from the
mount table and partitions from Slurm's ACLs.

  Storage (these grow to tens of GB -- keep them OFF your home filesystem)
  --storage-root PATH     Large-storage root the three directories default under
                          (discovered: ~/work, $SCRATCH, /data1/*/users/$USER ...)
  --image-dir PATH        Container images (.sif). May be someone else's, shared
                          read-only; see --no-sync.
  --r-libs-root PATH      YOUR R package libraries; one <ver>_singularity
                          subdirectory per R minor version. Never shared.
  --work-dir PATH         Session state, renv cache, container pull cache.

  Images
  --sync / --no-sync      Will you pull images into --image-dir yourself
                          (maintainer), or read a directory someone else keeps
                          in sync (consumer)? Auto-detected from write access.
  --share-images          chmod g+rx the image dir so your unix group can use it
  --r-versions "A B C"    R minor versions to set up (default: whatever images
                          are present, else 4.3 4.4 4.5 4.6)

  Cluster
  --cluster NAME          OnDemand cluster id (defaults to Slurm's ClusterName)
  --queue NAME            Default partition, pre-selected in the form
  --queues "A,B,C"        Partitions to offer in the Queue dropdown (default:
                          every partition your account may submit to)
  --sync-partition NAME   Partition that image pulls are submitted to
  --bind "P1,P2"          Host paths bound into the container (default: the
                          filesystems your chosen directories live on, plus
                          Slurm/munge)

  Install
  --app-dir PATH          Where to install the OnDemand app
                          (default: ~/ondemand/dev/rstudio_dev)
  --shell-init PATH|none  rc file to add the r-wrappers.sh source line to
  --link                  Symlink the app instead of copying it
  --yes, -y               Accept discovered defaults, do not prompt
  --dry-run               Print actions without performing them
  --help, -h              This message
EOF
}

while (( $# )); do
    case "$1" in
        --storage-root)    STORAGE_ROOT="$2"; shift 2 ;;
        --image-dir)       IMAGE_DIR="$2"; shift 2 ;;
        --r-libs-root)     R_LIBS_ROOT="$2"; shift 2 ;;
        --work-dir)        WORK_DIR="$2"; shift 2 ;;
        --r-versions)      R_VERSIONS="$2"; shift 2 ;;
        --sync)            SYNC_ROLE="maintainer"; shift ;;
        --no-sync)         SYNC_ROLE="consumer"; shift ;;
        --share-images)    SHARE_IMAGES="yes"; shift ;;
        --no-share-images) SHARE_IMAGES="no"; shift ;;
        --app-dir)         APP_DIR="$2"; shift 2 ;;
        --cluster)         CLUSTER="$2"; shift 2 ;;
        --queue)           QUEUE="$2"; shift 2 ;;
        --queues)          QUEUES="$2"; shift 2 ;;
        --sync-partition)  SYNC_PARTITION="$2"; shift 2 ;;
        --bind)            BIND_PATHS="$2"; shift 2 ;;
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
if (( DO_LINK )) && [[ -n ${RSTUDIO_DEV_BOOTSTRAP_TMP:-} ]]; then
    die "--link needs a persistent checkout; clone the repo and run ./install.sh --link from it"
fi

# ---------------------------------------------------------------- preflight --

echo
echo "RStudio Server (Open OnDemand) -- installer"
echo "==========================================="
echo
echo "This sets up three things, and asks you where each one goes:"
echo "  1. container images   (shared with anyone you like; ~2 GB each)"
echo "  2. R package libraries (yours alone; one per R minor version)"
echo "  3. session state + caches (yours alone; grows quietly)"
echo "It writes one config file that the OnDemand form, the job script and the"
echo "shell wrappers all read, so these choices are made exactly once."

if command -v singularity >/dev/null 2>&1; then
    CONTAINER_CMD=singularity
elif command -v apptainer >/dev/null 2>&1; then
    CONTAINER_CMD=apptainer
else
    die "neither singularity nor apptainer is on PATH"
fi

ALLOWED_LIST=""
if _slurm_probe; then
    ALLOWED_LIST="$(allowed_partitions)"
else
    warn "Slurm is not reachable from here; partitions cannot be discovered."
    warn "Pass --queue/--queues/--sync-partition explicitly, or edit the config afterwards."
fi

# ------------------------------------------------------------------- storage --

head2 "Storage"
echo "  The three directories below grow to tens of gigabytes. Home directories on"
echo "  HPC systems are small and quota'd, so they belong on large/scratch storage."
echo "  Your home filesystem: $(_fs_of "$HOME") ($(_avail_of "$HOME") free of $(_total_of "$HOME"))"

if [[ -z $STORAGE_ROOT ]]; then
    STORAGE_ROOT="$(pick_storage_root)"
    if [[ "$(readlink -f "$STORAGE_ROOT")" == "$(readlink -f "$HOME")" ]]; then
        warn "no large-storage directory found; falling back to your home directory."
        warn "If your site has scratch or project storage, pass --storage-root PATH."
    fi
fi
STORAGE_ROOT="${STORAGE_ROOT/#\~/$HOME}"
if interactive; then
    blank
    say "Large-storage root (the three directories default underneath it)"
    STORAGE_ROOT="$(ask "Storage root" "$STORAGE_ROOT")"
    STORAGE_ROOT="${STORAGE_ROOT/#\~/$HOME}"
fi

[[ -n $IMAGE_DIR   ]] || IMAGE_DIR="$STORAGE_ROOT/images/rstudio"
[[ -n $R_LIBS_ROOT ]] || R_LIBS_ROOT="$STORAGE_ROOT/R/x86_64-pc-linux-gnu-library"
[[ -n $WORK_DIR    ]] || WORK_DIR="$STORAGE_ROOT"

if interactive; then
    IMAGE_DIR="$(ask_big_dir \
        "Container images" \
        "holds the .sif images: $SZ_IMAGES. Point this at a colleague's directory to share theirs." \
        "Image directory" "$IMAGE_DIR")"
    R_LIBS_ROOT="$(ask_big_dir \
        "R package libraries (yours alone -- packages are built per R minor version)" \
        "$SZ_RLIBS." \
        "R library root" "$R_LIBS_ROOT")"
    WORK_DIR="$(ask_big_dir \
        "Session state and caches" \
        "$SZ_WORK. RStudio session slots live in <dir>/.rstudio-sessions, the shared renv cache in <dir>/.cache." \
        "Work directory" "$WORK_DIR")"
fi
IMAGE_DIR="${IMAGE_DIR/#\~/$HOME}"
R_LIBS_ROOT="${R_LIBS_ROOT/#\~/$HOME}"
WORK_DIR="${WORK_DIR/#\~/$HOME}"

# --------------------------------------------------------------------- images --

head2 "Images: do you maintain them, or use someone else's?"
echo "  The images are the one thing that CAN be shared -- they are identical for"
echo "  everyone. Whoever maintains a directory runs sync-images.sh; everybody else"
echo "  just reads it and never needs write access."

IMAGE_DIR_EXISTS=0
IMAGE_DIR_WRITABLE=0
IMAGE_DIR_OWNER=""
if [[ -d $IMAGE_DIR ]]; then
    IMAGE_DIR_EXISTS=1
    IMAGE_DIR_OWNER="$(stat -c '%U' "$IMAGE_DIR" 2>/dev/null || echo '?')"
    [[ -w $IMAGE_DIR ]] && IMAGE_DIR_WRITABLE=1
    # -r without -x lets you list a directory but not open anything inside it.
    [[ -x $IMAGE_DIR && -r $IMAGE_DIR ]] \
        || die "cannot read $IMAGE_DIR (owned by $IMAGE_DIR_OWNER). Ask its owner for group read+execute, or choose another --image-dir."
elif [[ -e $IMAGE_DIR ]]; then
    die "$IMAGE_DIR exists but is not a directory"
else
    # A path you cannot even stat looks identical to one that does not exist.
    # Say which it is, rather than reporting "does not exist" for a permissions
    # problem and sending the user off to look in the wrong place.
    parent="$(_nearest_existing "$IMAGE_DIR")"
    [[ -x $parent ]] || die "cannot reach $IMAGE_DIR: no access to $parent (owned by $(stat -c '%U' "$parent" 2>/dev/null || echo '?'))"
fi

if [[ -z $SYNC_ROLE ]]; then
    if (( IMAGE_DIR_EXISTS )) && (( ! IMAGE_DIR_WRITABLE )); then
        SYNC_ROLE="consumer"
        echo
        info "$IMAGE_DIR is owned by $IMAGE_DIR_OWNER and is not writable by you."
        info "-> consumer: you will use these images, and never sync them."
    elif interactive; then
        echo
        if confirm "Will you pull/update images in $IMAGE_DIR yourself?" Y; then
            SYNC_ROLE="maintainer"
        else
            SYNC_ROLE="consumer"
        fi
    else
        SYNC_ROLE="maintainer"
    fi
fi
if [[ $SYNC_ROLE == maintainer ]] && (( IMAGE_DIR_EXISTS )) && (( ! IMAGE_DIR_WRITABLE )); then
    die "--sync requested but $IMAGE_DIR is not writable (owned by $IMAGE_DIR_OWNER)"
fi

# Offer to open the image dir up to the unix group. Only meaningful for a
# maintainer, and only honest if the ancestors are traversable too.
if [[ $SYNC_ROLE == maintainer && -z $SHARE_IMAGES ]]; then
    if interactive; then
        echo
        info "Sharing: labmates can use your images if they can read this directory."
        confirm "Make $IMAGE_DIR group-readable (g+rx) so your unix group can use it?" Y \
            && SHARE_IMAGES=yes || SHARE_IMAGES=no
    else
        SHARE_IMAGES=no
    fi
fi

# ---------------------------------------------------------------- R versions --

# Only rstudio-<minor>.sif is recognised -- a legacy tag-named image like
# rstudio-v2.0.sif does not state which R it carries, and guessing is how you end
# up offering R 4.4 under a 4.5 label.
mapfile -t FOUND < <(find "$IMAGE_DIR" -maxdepth 1 -name 'rstudio-*.sif' -printf '%f\n' 2>/dev/null \
    | sed -nE 's/^rstudio-([0-9]+\.[0-9]+)\.sif$/\1/p' | sort -V)

if [[ $R_VERSIONS == auto ]]; then
    if (( ${#FOUND[@]} )); then
        R_VERSIONS="${FOUND[*]}"
    else
        R_VERSIONS="4.3 4.4 4.5 4.6"
    fi
fi
read -r -a VERSIONS <<<"$R_VERSIONS"

# ------------------------------------------------------------------- cluster --

head2 "Cluster and partitions"

if [[ -z $CLUSTER ]]; then
    CLUSTER="$(scontrol show config 2>/dev/null | awk -F'= *' '/^ClusterName/{print $2}' | tr -d ' ')"
    CLUSTER="${CLUSTER:-cluster}"
fi
echo "  The OnDemand cluster id must match a file in /etc/ood/config/clusters.d on"
echo "  the OnDemand WEB node -- which is not this machine, so it cannot be checked"
echo "  from here. Slurm calls this cluster '${CLUSTER}'; that is usually the same name."
if interactive; then
    CLUSTER="$(ask "OnDemand cluster id" "$CLUSTER")"
fi

if [[ -n $ALLOWED_LIST ]]; then
    mapfile -t ALLOWED < <(awk '{print $1}' <<<"$ALLOWED_LIST")
    echo
    echo "  Partitions your account may submit to (from Slurm's ACLs, filtered against"
    echo "  your accounts: ${MY_ACCOUNTS:-none reported}):"
    for p in "${ALLOWED[@]}"; do
        info "  $(_queue_label "$p" | cut -d'|' -f2-)"
    done

    # Default queue: the longest-running non-GPU partition the user may use. A
    # GPU partition is a deliberate choice (it costs a GPU), never a default.
    if [[ -z $QUEUE ]]; then
        best=""; best_t=-1
        for p in "${ALLOWED[@]}"; do
            _is_gpu_partition "$p" && continue
            t="$(_time_seconds "$(awk -v q="$p" '$1==q{print $2}' <<<"$ALLOWED_LIST")")"
            (( t > best_t )) && { best="$p"; best_t=$t; }
        done
        QUEUE="${best:-${ALLOWED[0]}}"
    fi
    # Offer everything the user may use; they can trim it.
    [[ -n $QUEUES ]] || QUEUES="$(IFS=,; printf '%s' "${ALLOWED[*]}")"
    # Image pulls are short and CPU-only: prefer a "short" partition, else the
    # shortest-limit non-GPU one, so a 20-minute pull does not sit in a queue
    # meant for week-long jobs.
    if [[ -z $SYNC_PARTITION ]]; then
        best=""; best_t=999999999
        for p in "${ALLOWED[@]}"; do
            _is_gpu_partition "$p" && continue
            t="$(_time_seconds "$(awk -v q="$p" '$1==q{print $2}' <<<"$ALLOWED_LIST")")"
            (( t >= 7200 && t < best_t )) && { best="$p"; best_t=$t; }
        done
        SYNC_PARTITION="${best:-$QUEUE}"
    fi
fi
[[ -n $QUEUE ]] || QUEUE="$(ask "Default Slurm partition" "")"
[[ -n $QUEUE ]] || die "no partition chosen and none could be discovered (pass --queue)"
[[ -n $QUEUES ]] || QUEUES="$QUEUE"
[[ -n $SYNC_PARTITION ]] || SYNC_PARTITION="$QUEUE"

if interactive; then
    echo
    QUEUE="$(ask "Default partition (pre-selected in the form)" "$QUEUE")"
    QUEUES="$(ask "Partitions to offer in the dropdown (comma-separated)" "$QUEUES")"
    SYNC_PARTITION="$(ask "Partition for image pulls (short CPU job)" "$SYNC_PARTITION")"
fi

# A partition Slurm has never heard of is a typo, and it will not fail until the
# user clicks Launch. Say so now.
if [[ -n $ALLOWED_LIST ]]; then
    for q in ${QUEUES//,/ } "$QUEUE" "$SYNC_PARTITION"; do
        q="${q%%|*}"
        grep -qx -- "$q" <<<"$(awk '{print $1}' <<<"$ALLOWED_LIST")" \
            || warn "partition '$q' is not one your account may submit to; jobs will be rejected"
    done
fi

# ---------------------------------------------------------------------- binds --

# The container sees only what is bound into it. Bind the filesystems the chosen
# directories actually live on -- derived, not hard-coded to any one site's
# /data1 -- plus Slurm/munge so jobs can be submitted from inside R. Paths that
# do not exist at session start are skipped at runtime.
if [[ -z $BIND_PATHS ]]; then
    # Bind the top-level filesystem each directory sits under (/data1, /scratch,
    # ...), never a system directory: $HOME is bound explicitly by the job script,
    # and /tmp is where it binds the job's own private $TMPDIR -- blanket-binding
    # the host's /tmp over that would shadow the container's writable temp space.
    SYSTEM_TOPS=" / /bin /boot /dev /etc /home /lib /lib64 /proc /run /sbin /sys /tmp /usr /var "
    declare -A seen=()
    for d in "$IMAGE_DIR" "$R_LIBS_ROOT" "$WORK_DIR"; do
        real="$(readlink -f "$(_nearest_existing "$d")")"
        top="/$(cut -d/ -f2 <<<"$real")"
        [[ $SYSTEM_TOPS == *" $top "* ]] && continue
        seen["$top"]=1
    done
    for p in /run/munge /etc/slurm /usr/lib64/slurm /usr/lib64/libmunge.so.2; do
        [[ -e $p ]] && seen["$p"]=1
    done
    # Sorted so re-running the installer produces the same config file rather
    # than a reshuffled one (bash associative arrays have no stable order).
    BIND_PATHS="$(printf '%s\n' "${!seen[@]}" | sort | paste -sd, -)"
fi

# --------------------------------------------------------- storage safety net --

# The interactive interview warns and asks again when an answer lands on the home
# filesystem. This pass repeats the check for the paths as finally settled --
# including under --yes and `curl | bash`, which is precisely the run where
# nobody was asked anything and a 30 GB image directory can quietly land on a
# 100 GB shared home filesystem.
HOME_FS_HITS=0
warn_if_home_fs() {  # warn_if_home_fs <label> <path> <what-grows-here>
    on_home_fs "$2" || return 0
    warn "$1 is on your HOME filesystem: $2"
    warn "    $(_fs_of "$2"): $(_avail_of "$2") free of $(_total_of "$2") -- $3"
    HOME_FS_HITS=$(( HOME_FS_HITS + 1 ))
}
warn_if_home_fs "Image directory"  "$IMAGE_DIR"   "$SZ_IMAGES"
warn_if_home_fs "R library root"   "$R_LIBS_ROOT" "$SZ_RLIBS"
warn_if_home_fs "Work directory"   "$WORK_DIR"    "$SZ_WORK"
if (( HOME_FS_HITS )); then
    warn "Home filesystems on HPC are small, quota'd and shared; filling one breaks logins."
    warn "Re-run with --storage-root /path/to/large/storage to move these off it."
fi

# ----------------------------------------------------------------------- plan --

QUEUES_OUT="$(_enrich_queues "$QUEUES")"

head2 "Plan"
info "$(printf '%-16s %s' 'images' "$IMAGE_DIR")"
info "$(printf '%-16s %s' '' "${#FOUND[@]} found: ${FOUND[*]:-none} · role: $SYNC_ROLE$( [[ $SHARE_IMAGES == yes ]] && echo ' · will chmod g+rx')")"
info "$(printf '%-16s %s' 'R libraries' "$R_LIBS_ROOT")"
info "$(printf '%-16s %s' '' "one <ver>_singularity dir per version: ${VERSIONS[*]}")"
info "$(printf '%-16s %s' 'work dir' "$WORK_DIR")"
info "$(printf '%-16s %s' '' ".rstudio-sessions/ (session slots) · .cache/ (renv + pull cache)")"
info "$(printf '%-16s %s' 'app' "$APP_DIR  $( ((DO_LINK)) && echo '(symlink)' || echo '(copy)')")"
info "$(printf '%-16s %s' 'config' "$CONFIG_PATH")"
info "$(printf '%-16s %s' 'container' "$CONTAINER_CMD")"
info "$(printf '%-16s %s' 'binds' "$BIND_PATHS")"
info "$(printf '%-16s %s' 'cluster' "$CLUSTER")"
info "$(printf '%-16s %s' 'default queue' "$QUEUE")"
info "$(printf '%-16s %s' 'sync partition' "$SYNC_PARTITION")"
if [[ -n $QUEUES_OUT ]]; then
    info "$(printf '%-16s' 'queue dropdown')"
    printf '%s\n' "$QUEUES_OUT" | tr ',' '\n' | sed 's/^/                   /'
fi
echo

if interactive; then
    confirm "Proceed?" Y || { echo "aborted."; exit 0; }
fi

# ------------------------------------------------------------------- R libs --

head2 "R package libraries"
echo "  Packages are compiled against a specific R minor version, so each version"
echo "  gets its own directory. R silently ignores a missing R_LIBS_USER, so the"
echo "  form only offers versions whose library exists -- these are those."
for v in "${VERSIONS[@]}"; do
    lib="$R_LIBS_ROOT/${v}_singularity"
    if [[ -d $lib ]]; then
        n=$(find "$lib" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
        info "exists   $lib ($n packages)"
    else
        info "create   $lib"
        do_mkdir "$lib"
    fi
    [[ -e $IMAGE_DIR/rstudio-$v.sif ]] \
        || warn "R $v has a library but no image yet; it will appear in the form once the image is pulled"
done

# ------------------------------------------------------------------ work dir --

head2 "Session state and caches"
info "create   $WORK_DIR/.rstudio-sessions   (one directory per named session slot)"
info "create   $WORK_DIR/.cache              (shared renv package cache + container pull cache)"
do_mkdir "$WORK_DIR/.rstudio-sessions"
do_mkdir "$WORK_DIR/.cache"

# -------------------------------------------------------------------- images --

head2 "Images"
if [[ $SYNC_ROLE == maintainer ]]; then
    if (( ! IMAGE_DIR_EXISTS )); then
        info "create   $IMAGE_DIR"
        do_mkdir "$IMAGE_DIR"
    else
        info "exists   $IMAGE_DIR"
    fi
    if [[ $SHARE_IMAGES == yes ]]; then
        info "chmod    g+rx $IMAGE_DIR"
        dry || chmod g+rx "$IMAGE_DIR" 2>/dev/null \
            || warn "could not chmod $IMAGE_DIR"
        blocked="$(group_blocked_ancestors "$IMAGE_DIR")"
        if [[ -n $blocked ]]; then
            warn "your group still cannot reach it: these parent directories deny group access:"
            printf '%s' "$blocked" | sed 's/^/         /' >&2
            warn "run 'chmod g+x <dir>' on each, or put the images somewhere group-traversable"
        fi
    fi
    info "sync     you maintain this directory: run sync-images.sh to pull images"
else
    info "read     $IMAGE_DIR (maintained by ${IMAGE_DIR_OWNER:-someone else})"
    info "sync     not yours to sync; sync-images.sh will refuse to write here"
fi

# ----------------------------------------------------------------- app files --

head2 "Application"
if [[ "$(readlink -f "$SRC_DIR")" == "$(readlink -f "$APP_DIR" 2>/dev/null)" ]]; then
    info "in place $APP_DIR (running from the checkout)"
elif (( DO_LINK )); then
    info "symlink  $APP_DIR -> $SRC_DIR"
    do_mkdir "$(dirname "$APP_DIR")"
    dry || ln -sfn "$SRC_DIR" "$APP_DIR"
else
    info "copy     $SRC_DIR -> $APP_DIR"
    do_mkdir "$APP_DIR"
    dry || cp -r "$SRC_DIR/." "$APP_DIR/"
fi
dry || chmod +x "$APP_DIR/sync-images.sh" 2>/dev/null || true

# ------------------------------------------------------------------- config --

head2 "Configuration"
info "write    $CONFIG_PATH"
CONFIG_BODY="$(cat <<EOF
# Written by rstudio_dev/install.sh on $(date -Iseconds)
#
# Read by the OnDemand form (form.yml.erb), the job script (script.sh.erb),
# sync-images.sh and r-wrappers.sh. A file, not environment variables, because
# OnDemand renders the ERB templates inside the PUN, which does not reliably
# source your shell rc. Environment variables still win when set, so one-off
# overrides work. Absolute paths only; no shell expansion is performed.

# --- storage ---------------------------------------------------------------
# Container images. Shared: read access is all you need unless you sync them.
RSTUDIO_IMAGE_DIR=$IMAGE_DIR

# Your R package libraries: one <ver>_singularity subdirectory per R minor
# version. NOT shareable -- packages are built against a specific R.
R_LIBS_ROOT=$R_LIBS_ROOT

# Session state and caches. <dir>/.rstudio-sessions/<slot> holds each named
# session's RStudio state; <dir>/.cache is the SHARED renv package cache
# (XDG_CACHE_HOME) and the container pull cache. Keep this off your home
# filesystem -- it grows to tens of GB.
RSTUDIO_WORK_DIR=$WORK_DIR

# Host paths bound into the container, comma-separated, beyond \$HOME (always
# bound). Derived from the filesystems the directories above live on, plus
# Slurm/munge so jobs can be submitted from inside R. Paths that do not exist on
# the compute node are skipped at session start.
RSTUDIO_BIND_PATHS=$BIND_PATHS

# --- images ----------------------------------------------------------------
# maintainer = you pull images into RSTUDIO_IMAGE_DIR with sync-images.sh.
# consumer   = someone else keeps that directory current; you only read it.
RSTUDIO_SYNC_ROLE=$SYNC_ROLE

# R minor versions to track when syncing images.
RSTUDIO_VERSIONS=${VERSIONS[*]}

# Container runtime.
RSTUDIO_SINGULARITY=$CONTAINER_CMD

# --- cluster ---------------------------------------------------------------
# OnDemand cluster id: must match a file in /etc/ood/config/clusters.d on the
# OnDemand web node (not checkable from a login node).
RSTUDIO_CLUSTER=$CLUSTER

# Default Slurm partition, pre-selected in the form.
RSTUDIO_QUEUE=$QUEUE

# Partitions offered in the Queue dropdown, comma-separated. Each entry is
# 'partition' or 'partition|label'; install.sh generates the labels from Slurm
# (GPU type, wall-clock limit) because the form cannot reach Slurm from the PUN.
# Discovered from the partition ACLs your account may submit to -- re-run
# install.sh if your access changes.
RSTUDIO_QUEUES=$QUEUES_OUT

# Partition that sync-images.sh submits image pulls to. The pull is ~2 GB per
# image plus a squashfs build, so it does not belong on a login node.
RSTUDIO_SYNC_PARTITION=$SYNC_PARTITION
EOF
)"
if dry; then
    printf '%s\n' "$CONFIG_BODY" | sed 's/^/    | /'
else
    mkdir -p "$(dirname "$CONFIG_PATH")"
    printf '%s\n' "$CONFIG_BODY" >"$CONFIG_PATH"
    chmod 0644 "$CONFIG_PATH"
fi

# -------------------------------------------------------------- shell init --

head2 "Shell wrappers"
echo "  r-wrappers.sh gives you R_ / Rscript_ / bash_ / sync_images: the same images"
echo "  and libraries as the OnDemand app, from a terminal."
SRC_LINE="source \"$APP_DIR/r-wrappers.sh\""
if [[ -z $SHELL_INIT ]]; then
    if interactive; then
        SHELL_INIT="$(ask "Add the source line to which rc file? ('none' to skip)" "$HOME/.bashrc")"
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
    if dry; then
        printf '  [dry-run] would append:\n    | # rstudio_dev\n    | %s\n' "$SRC_LINE"
    else
        printf '\n# rstudio_dev -- R/RStudio singularity wrappers\n%s\n' "$SRC_LINE" >>"$SHELL_INIT"
    fi
fi

# ----------------------------------------------------------------- summary --

head2 "Done"
echo "  What this touched:"
info "  $CONFIG_PATH            (config; delete to uninstall)"
info "  $APP_DIR       (the OnDemand app)"
info "  $R_LIBS_ROOT/<ver>_singularity   (your R libraries)"
info "  $WORK_DIR/{.rstudio-sessions,.cache}   (session state + caches)"
[[ $SYNC_ROLE == maintainer ]] && info "  $IMAGE_DIR             (images)"
[[ $SHELL_INIT != none ]] && info "  $SHELL_INIT              (one source line)"

head2 "Next steps"
if [[ $SYNC_ROLE == maintainer ]]; then
    if (( ${#FOUND[@]} == 0 )); then
        echo "  1. Pull the images:   $APP_DIR/sync-images.sh --sync"
        echo "     (submits a Slurm job to $SYNC_PARTITION; ~2 GB per R version)"
    else
        echo "  1. Check the images:  $APP_DIR/sync-images.sh"
    fi
else
    echo "  1. Images are maintained by ${IMAGE_DIR_OWNER:-someone else}; nothing to pull."
    echo "     Check what is there: $APP_DIR/sync-images.sh"
fi
[[ $SHELL_INIT == none ]] \
    && echo "  2. Source the wrappers:  $SRC_LINE" \
    || echo "  2. Reload your shell:    source $SHELL_INIT"
echo "  3. Open OnDemand -> Interactive Apps -> RStudio Server"
echo
echo "  Your R libraries start empty. Install packages from inside RStudio, or:"
echo "      Rscript_ -e 'install.packages(\"data.table\")'"
echo
if dry; then echo "  (dry run: nothing was changed)"; fi
