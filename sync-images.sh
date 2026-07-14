#!/usr/bin/env bash
#
# sync-images.sh -- keep the RStudio Singularity images on this cluster in step
# with the container images published by https://github.com/mjz1/rstudio-img
#
# The registry is the source of truth. Every local image carries a `.digest`
# sidecar recording the registry manifest digest it was pulled from, so drift is
# detected with three HTTP HEAD requests instead of a 4 GB download.
#
#   sync-images.sh                  check; on a terminal, offers to pull if stale
#   sync-images.sh --sync           pull stale images (submits an sbatch job)
#   sync-images.sh --sync --local   pull inline, for use inside an allocation
#   sync-images.sh --sync 4.6       restrict to specific R versions
#   sync-images.sh --watch          follow the running/submitted sync job's log
#   sync-images.sh --image-dir P    one-off target for THIS run (config unchanged;
#                                   re-run install.sh to move images permanently)
#   sync-images.sh --manifest       rebuild images.json from what is on disk
#
# Images are rolled in place but the previous build is retained as
# `rstudio-<ver>.sif.prev` (a hardlink, so it costs no extra disk until the new
# image lands). Rollback is therefore a rename, not a re-pull.
#
# Configuration comes from ~/.config/rstudio_dev/config (written by install.sh);
# the environment overrides it. The keys that matter here:
#
#   RSTUDIO_IMAGE_DIR   where .sif files live          (shared artifact)
#   R_LIBS_ROOT         where R package libraries live (per-user)
#   RSTUDIO_VERSIONS    space-separated R minor versions to track
#   RSTUDIO_WORK_DIR    holds the container pull cache (.cache/singularity)
#   RSTUDIO_SYNC_ROLE   maintainer = may pull; consumer = read-only, --sync refused
#   RSTUDIO_SINGULARITY container runtime (singularity | apptainer)
#
set -euo pipefail

# Config file written by install.sh; environment still wins over it.
# shellcheck source=conf.sh
[ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/conf.sh" ] \
    && . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/conf.sh"

IMAGE_DIR="${RSTUDIO_IMAGE_DIR:-$HOME/work/images/rstudio}"
R_LIBS_ROOT="${R_LIBS_ROOT:-$HOME/work/R/x86_64-pc-linux-gnu-library}"
WORK_DIR="${RSTUDIO_WORK_DIR:-$HOME/work}"
SINGULARITY="${RSTUDIO_SINGULARITY:-singularity}"
SYNC_ROLE="${RSTUDIO_SYNC_ROLE:-maintainer}"
GHCR_REPO="${RSTUDIO_GHCR_REPO:-mjz1/rstudio-img}"
DOCKER_REPO="${RSTUDIO_DOCKER_REPO:-zatzmanm/rstudio}"
KEEP_PREV="${RSTUDIO_KEEP_PREV:-1}"

read -r -a VERSIONS <<<"${RSTUDIO_VERSIONS:-4.3 4.4 4.5 4.6}"

SBATCH_PARTITION="${RSTUDIO_SYNC_PARTITION:-cpushort}"
SBATCH_TIME="${RSTUDIO_SYNC_TIME:-02:00:00}"
SBATCH_CPUS="${RSTUDIO_SYNC_CPUS:-2}"
SBATCH_MEM="${RSTUDIO_SYNC_MEM:-8G}"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MANIFEST="$IMAGE_DIR/images.json"
LOGDIR="$IMAGE_DIR/.sync-logs"

# Registries serve the manifest under whichever media type the client asks for.
# Ask for all four or the digest header comes back empty for multi-arch indexes.
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

# Shared UI kit (colour/glyphs, degrading to plain when not a TTY). Fallbacks
# below keep a lone copy of this script working without its siblings.
if [ -r "$(dirname "$SELF")/ui.sh" ]; then
    # shellcheck source=ui.sh
    . "$(dirname "$SELF")/ui.sh"
else
    C_R='' C_B='' C_DIM='' C_HDR='' C_OK='' C_WARN='' C_ERR=''
    G_OK='ok' G_BAD='x' G_WARN='!' G_DOT='/'
    die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
    warn() { printf '! warn: %s\n' "$*" >&2; }
    note() { printf '  %s\n' "$*"; }
    ok()   { printf '  %s %s\n' "$G_OK" "$*"; }
fi
log()  { printf '%s\n' "$*" >&2; }

# A controlling terminal we may prompt on. Same /dev/tty gate as install.sh.
_tty() { [[ -e /dev/tty ]] && (exec </dev/tty) 2>/dev/null; }

# --- registry -----------------------------------------------------------------

_json_field() { python3 -c 'import sys,json; print(json.load(sys.stdin)["'"$1"'"])'; }

_ghcr_token()     { curl -fsS "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull" | _json_field token; }
_dockerhub_token(){ curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${DOCKER_REPO}:pull" | _json_field token; }

# _digest <host> <repo> <token> <tag>
_digest() {
    curl -fsSI -H "Authorization: Bearer $3" -H "Accept: $ACCEPT" \
        "https://$1/v2/$2/manifests/$4" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# Echo "<digest> <repo-ref>" for a tag. GHCR first, Docker Hub as fallback; the
# publish workflow pushes an identical image to both, so either is authoritative.
registry_digest() {
    local tag="$1" tok dig
    if tok=$(_ghcr_token) && dig=$(_digest ghcr.io "$GHCR_REPO" "$tok" "$tag") && [[ -n $dig ]]; then
        printf '%s ghcr.io/%s\n' "$dig" "$GHCR_REPO"; return 0
    fi
    if tok=$(_dockerhub_token) && dig=$(_digest registry-1.docker.io "$DOCKER_REPO" "$tok" "$tag") && [[ -n $dig ]]; then
        printf '%s %s\n' "$dig" "$DOCKER_REPO"; return 0
    fi
    return 1
}

local_digest() { local f="$IMAGE_DIR/rstudio-$1.sif.digest"; [[ -r $f ]] && cat "$f" || true; }

short() { printf '%.19s…' "${1#sha256:}"; }

# --- image introspection ------------------------------------------------------

# The images are already self-describing, so nothing upstream needs to change:
# rocker's base carries OCI labels and R/RStudio/Quarto each report a version.
introspect() {
    local sif="$1" r rstudio quarto
    r=$("$SINGULARITY" exec "$sif" R --version 2>/dev/null | sed -nE '1s/^R version ([0-9.]+).*/\1/p') || true
    rstudio=$("$SINGULARITY" exec "$sif" rstudio-server version 2>/dev/null | awk 'NR==1{print $1}') || true
    quarto=$("$SINGULARITY" exec "$sif" quarto --version 2>/dev/null | head -1) || true
    printf '%s\t%s\t%s\n' "${r:-unknown}" "${rstudio:-unknown}" "${quarto:-unknown}"
}

write_info() { # write_info <ver> <digest> <ref> <r_full> <rstudio> <quarto>
    python3 - "$IMAGE_DIR/rstudio-$1.sif.info" "$@" <<'PY'
import json, sys, datetime
out, ver, digest, ref, r_full, rstudio, quarto = sys.argv[1:8]
json.dump({
    "r_version": ver, "digest": digest, "source": ref,
    "r_full": r_full, "rstudio": rstudio, "quarto": quarto,
    "pulled_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}, open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
}

# --- pulling ------------------------------------------------------------------

pull_one() { # pull_one <ver> <digest> <repo-ref>
    local ver="$1" digest="$2" ref="$3"
    local target="$IMAGE_DIR/rstudio-$ver.sif"
    local tmp="$IMAGE_DIR/.rstudio-$ver.$$.partial.sif"

    # The 8 GB directory literally named '~' in the image dir came from an
    # unexpanded tilde here. Set it explicitly, and skip the blob cache
    # entirely: it doubles peak disk for images we pull once a month.
    export SINGULARITY_CACHEDIR="${SINGULARITY_CACHEDIR:-$WORK_DIR/.cache/singularity}"
    mkdir -p "$SINGULARITY_CACHEDIR"

    log "==> R $ver: pulling $ref@$(short "$digest")"
    "$SINGULARITY" pull --disable-cache "$tmp" "docker://${ref}@${digest}" >&2

    local info r_full rstudio quarto
    info=$(introspect "$tmp")
    IFS=$'\t' read -r r_full rstudio quarto <<<"$info"

    # Guard against a tag that no longer holds the R version it claims -- the
    # exact class of mistake that let rstudio-v2.0.sif silently mean R 4.4.1.
    [[ $r_full == ${ver}.* || $r_full == "$ver" ]] \
        || die "R $ver: image reports R $r_full; refusing to install (digest $digest)"

    # Retain the outgoing build as a hardlink, then swap the name atomically.
    # There is no window in which rstudio-<ver>.sif does not resolve, so an
    # OnDemand session starting mid-sync can never see a partial image.
    if [[ -e $target ]]; then
        if (( KEEP_PREV > 0 )); then
            ln -f "$target" "$target.prev"
            [[ -r $target.digest ]] && cp -f "$target.digest" "$target.prev.digest"
        else
            rm -f "$target.prev" "$target.prev.digest"
        fi
    fi
    mv -f "$tmp" "$target"
    chmod 0755 "$target"
    printf '%s\n' "$digest" >"$target.digest"
    write_info "$ver" "$digest" "$ref" "$r_full" "$rstudio" "$quarto"
    # The .sif is chmod'd explicitly, but the sidecars inherit the maintainer's
    # umask -- and under umask 077 they come out group-unreadable, which quietly
    # breaks every CONSUMER: their form loses its version labels and their check
    # reports every image UNKNOWN. Sidecars exist to be read by people who are
    # not the maintainer, so their mode must not depend on who ran the pull.
    chmod 0644 "$target.digest" "$target.info" 2>/dev/null || true

    log "    installed R $r_full, RStudio $rstudio, Quarto $quarto"
}

update_latest_symlink() {
    local newest
    newest=$(find "$IMAGE_DIR" -maxdepth 1 -name 'rstudio-[0-9]*.sif' -printf '%f\n' 2>/dev/null \
        | sed -nE 's/^rstudio-([0-9]+\.[0-9]+)\.sif$/\1/p' | sort -V | tail -1)
    [[ -n $newest ]] || return 0
    ln -sfn "rstudio-$newest.sif" "$IMAGE_DIR/rstudio-latest.sif"
    log "==> rstudio-latest.sif -> rstudio-$newest.sif"
}

rebuild_manifest() {
    python3 - "$MANIFEST" "$IMAGE_DIR" <<'PY'
import glob, json, os, re, sys
out, d = sys.argv[1], sys.argv[2]
entries = []
for p in sorted(glob.glob(os.path.join(d, "rstudio-*.sif.info"))):
    with open(p) as fh:
        entries.append(json.load(fh))
entries.sort(key=lambda e: [int(x) for x in e["r_version"].split(".")], reverse=True)
with open(out, "w") as fh:
    json.dump(entries, fh, indent=2)
    fh.write("\n")
print(f"wrote {out} ({len(entries)} images)", file=sys.stderr)
PY
    chmod 0644 "$MANIFEST" 2>/dev/null || true   # same umask reasoning as the sidecars
}

# --- presentation ---------------------------------------------------------------

# "pulled 12d ago", from the ISO-8601 pulled_at in the .info sidecar.
_age_of() {
    local ts then now d
    ts=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pulled_at",""))' "$1" 2>/dev/null) || return 1
    [[ -n $ts ]] || return 1
    then=$(date -d "$ts" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    d=$(( (now - then) / 86400 ))
    case $d in 0) printf 'today' ;; 1) printf 'yesterday' ;; *) printf '%dd ago' "$d" ;; esac
}

_row() {  # _row <colour> <glyph> <ver> <status> <detail>
    printf '  %s%s%s %-5s %s%-11s%s %s
' "$1" "$2" "$C_R" "$3" "$1" "$4" "$C_R" "$5"
}

# The one sync job we ever run at a time, if it is queued or running now.
# Echoes "<jobid> <state> <elapsed>"; empty when none.
running_sync_job() {
    command -v squeue >/dev/null 2>&1 || return 0
    # Excluding our OWN job id (not "any job") is what lets a human inside an
    # salloc still get job-awareness while the sbatch'd sync job never sees
    # itself and refuses to run.
    squeue -h -u "$USER" -n rstudio-img-sync -o '%i %T %M' 2>/dev/null         | awk -v me="${SLURM_JOB_ID:-}" '$1 != me' | head -1
}

# --- commands -----------------------------------------------------------------

# Populates STALE[] with versions whose local digest != registry digest.
declare -a STALE=()
declare -A REMOTE_DIGEST=() REMOTE_REF=()

check() {
    local ver loc rem ref line age info
    printf '    %-5s %-11s %s\n' "R" "STATUS" "DETAIL"
    for ver in "${VERSIONS[@]}"; do
        info="$IMAGE_DIR/rstudio-$ver.sif.info"
        age="$(_age_of "$info" || true)"
        if ! line=$(registry_digest "$ver"); then
            _row "$C_WARN" "$G_WARN" "$ver" "UNREACHABLE" "no digest from either registry"
            continue
        fi
        rem=${line%% *}; ref=${line##* }
        REMOTE_DIGEST[$ver]=$rem; REMOTE_REF[$ver]=$ref
        loc=$(local_digest "$ver")

        if [[ ! -e $IMAGE_DIR/rstudio-$ver.sif ]]; then
            STALE+=("$ver")
            _row "$C_ERR" "$G_BAD" "$ver" "MISSING" "never pulled $G_DOT $(short "$rem")"
        elif [[ -z $loc ]]; then
            STALE+=("$ver")
            _row "$C_WARN" "$G_WARN" "$ver" "UNKNOWN" "no .digest sidecar; will re-pull"
        elif [[ $loc != "$rem" ]]; then
            STALE+=("$ver")
            _row "$C_WARN" "$G_WARN" "$ver" "STALE" "tag moved $(short "$loc") -> $(short "$rem")${age:+ $G_DOT pulled $age}"
        else
            local detail=""
            if [[ -r $info ]]; then
                # %-format, not an f-string: this cluster's python3 is 3.6.
                detail="$(python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("R %s %s RStudio %s" % (i["r_full"], sys.argv[2], i["rstudio"]))' "$info" "$G_DOT" 2>/dev/null || true)"
            fi
            detail="${detail:-$(short "$rem")}${age:+ $G_DOT pulled $age}"
            _row "$C_OK" "$G_OK" "$ver" "up to date" "$detail"
        fi
    done
    if [[ -d $R_LIBS_ROOT ]]; then
        for ver in "${VERSIONS[@]}"; do
            [[ -d "$R_LIBS_ROOT/${ver}_singularity" ]] \
                || log "warning: R $ver has no package library at $R_LIBS_ROOT/${ver}_singularity (it will not appear in the OnDemand form)"
        done
    fi
}

sync_local() {
    local ver
    exec 9>"$IMAGE_DIR/.sync.lock"
    flock -n 9 || die "another sync holds $IMAGE_DIR/.sync.lock"
    for ver in "$@"; do
        pull_one "$ver" "${REMOTE_DIGEST[$ver]}" "${REMOTE_REF[$ver]}"
    done
    update_latest_symlink
    rebuild_manifest
}

SYNC_JID=""
sync_sbatch() {
    mkdir -p "$LOGDIR"
    local jid
    jid=$(sbatch --parsable \
        --job-name=rstudio-img-sync \
        --partition="$SBATCH_PARTITION" \
        --time="$SBATCH_TIME" \
        --cpus-per-task="$SBATCH_CPUS" \
        --mem="$SBATCH_MEM" \
        --output="$LOGDIR/sync-%j.log" \
        "$SELF" --sync --local "$@")
    SYNC_JID="$jid"
    ok "submitted job $jid to pull: $*" >&2
    log "    log: $LOGDIR/sync-$jid.log"
}

# Follow a sync job: poll its state, tail its log once it exists, and re-check
# when it leaves the queue. Ctrl-C detaches; the job is unaffected.
watch_job() {
    local jid="$1" logf="$LOGDIR/sync-$1.log" state prev="" tailpid=""
    trap 'kill "$tailpid" 2>/dev/null; echo; note "detached -- job $jid continues; log: $logf"; exit 0' INT
    while :; do
        state="$(squeue -h -j "$jid" -o '%T' 2>/dev/null || true)"
        [[ -z $state ]] && break
        if [[ $state != "$prev" ]]; then
            note "job $jid $G_DOT $state"
            prev="$state"
        fi
        if [[ -z $tailpid && -f $logf ]]; then
            tail -n +1 -f "$logf" & tailpid=$!
        fi
        sleep 5
    done
    sleep 1; kill "$tailpid" 2>/dev/null; wait "$tailpid" 2>/dev/null || true
    trap - INT
    ok "job $jid finished -- re-checking" >&2
    STALE=()
    check
}

# Print the header comment as the help text: everything from line 2 up to the
# first non-comment line. (A hard-coded line range silently truncates the moment
# someone adds a line to the header.)
usage() { awk 'NR==1{next} /^#/{sub(/^#[[:space:]]?/,""); print; next} {exit}' "$SELF"; }

main() {
    local do_sync=0 force_local=0 do_manifest=0 do_watch=0 oneoff_dir=""
    local -a want=()
    while (( $# )); do
        case "$1" in
            --sync)      do_sync=1 ;;
            --local)     force_local=1 ;;
            --check)     do_sync=0 ;;
            --watch)     do_watch=1 ;;
            --image-dir) oneoff_dir="$2"; shift ;;
            --manifest)  do_manifest=1 ;;
            -h|--help)   usage; return 0 ;;
            -*)          die "unknown option: $1 (try --help)" ;;
            *)           want+=("$1") ;;
        esac
        shift
    done
    (( ${#want[@]} )) && VERSIONS=("${want[@]}")

    # --image-dir redirects THIS run only. Moving images permanently is
    # install.sh's job -- one writer per config key -- so say that out loud
    # rather than letting a scratch experiment look like a migration.
    if [[ -n $oneoff_dir ]]; then
        IMAGE_DIR="${oneoff_dir/#\~/$HOME}"
        MANIFEST="$IMAGE_DIR/images.json"
        LOGDIR="$IMAGE_DIR/.sync-logs"
        [[ -w $IMAGE_DIR || ! -d $IMAGE_DIR ]] && SYNC_ROLE=maintainer
        warn "one-off target $IMAGE_DIR (config unchanged; re-run install.sh to move images permanently)"
    fi

    # Where this run reads from and writes to -- the question every sync tool
    # should answer before it is asked.
    local owner=""
    [[ -d $IMAGE_DIR ]] && owner="$(stat -c '%U' "$IMAGE_DIR" 2>/dev/null || echo '?')"
    head2 "sync-images $G_DOT $IMAGE_DIR"
    note "role: $SYNC_ROLE${owner:+ (owner: $owner)} $G_DOT registry: ghcr.io/$GHCR_REPO"

    # Update notice for the app itself (never auto-applied): deployed stamp vs
    # the repo's VERSION. Silent on any failure; sync already talks to the net.
    local _appdir="${RSTUDIO_APP_DIR:-$HOME/ondemand/dev/rstudio_dev}"
    if [[ -r ${_appdir}/.deployed-version ]]; then
        local _dep _latest
        _dep="$(awk '{print $1}' "${_appdir}/.deployed-version" 2>/dev/null)"
        _latest="$(curl -fsS --max-time 3 https://raw.githubusercontent.com/mjz1/rstudio-ood/master/VERSION 2>/dev/null | head -1)"
        if [[ -n $_latest && -n $_dep && $_latest != "$_dep" ]]; then
            warn "app update available: $_dep -> $_latest"
            log  "    update: curl -fsSL https://raw.githubusercontent.com/mjz1/rstudio-ood/master/install.sh | bash -s -- --app-only"
        fi
    fi

    [[ -d $IMAGE_DIR ]] || die "image dir not found: $IMAGE_DIR"
    command -v "$SINGULARITY" >/dev/null || die "$SINGULARITY not on PATH"

    # One sync at a time. A queued/running job already holds (or will hold) the
    # lock; a second submission would just sit on it, so point at the live one
    # instead. --watch attaches to it.
    local running=""
    if ! (( force_local )); then
        running="$(running_sync_job)"
        if [[ -n $running ]]; then
            set -- $running
            warn "a sync job is already ${2,,} (job $1, ${3:-?} elapsed)"
            log  "    log: $LOGDIR/sync-$1.log"
            if (( do_watch )); then watch_job "$1"; return 0; fi
            (( do_sync )) && die "not submitting a second sync; --watch to follow job $1"
        fi
    fi

    # Checking is safe for everyone; pulling is not. Someone using a colleague's
    # image directory has no business writing to it, and finding that out as a
    # permission-denied error halfway through a 2 GB pull (on a compute node,
    # in a log they have to go and find) helps nobody. Say it up front.
    if (( do_sync )); then
        if [[ $SYNC_ROLE == consumer ]]; then
            die "config says you are a CONSUMER of $IMAGE_DIR (maintained by $(stat -c '%U' "$IMAGE_DIR" 2>/dev/null || echo 'someone else')).
       Ask them to run --sync, or re-run install.sh with --sync and your own --image-dir."
        fi
        [[ -w $IMAGE_DIR ]] || die "cannot write to $IMAGE_DIR (owned by $(stat -c '%U' "$IMAGE_DIR" 2>/dev/null || echo '?')).
       Re-run install.sh and choose an image directory you own, or ask the owner to sync."
    fi

    # Covers `die` inside pull_one, which exits rather than returning.
    trap 'rm -f "$IMAGE_DIR"/.rstudio-*.'"$$"'.partial.sif' EXIT

    if (( do_manifest )); then rebuild_manifest; return 0; fi

    check

    # On a terminal, a bare check that finds stale images ends with an offer to
    # fix them -- the friendly entrypoint. Everything non-interactive (scripts,
    # the sbatch job itself, consumers) keeps the check-only behaviour.
    if ! (( do_sync )) && (( ${#STALE[@]} )) && [[ -z $running ]] \
       && [[ $SYNC_ROLE != consumer && -w $IMAGE_DIR ]] && _tty; then
        local reply how="sbatch -> $SBATCH_PARTITION"
        # Inside an allocation the pull runs right here (see the branch below);
        # the prompt must not promise an sbatch that will not happen.
        [[ -n ${SLURM_JOB_ID:-} ]] && how="inline, on this node"
        read -r -p "  Pull ${#STALE[@]} image(s) now ($how)? [Y/n]: " reply </dev/tty
        [[ -z ${reply:-} || $reply =~ ^[Yy] ]] && do_sync=1
    fi
    (( do_sync )) || return 0

    if (( ${#STALE[@]} == 0 )); then ok "nothing to do" >&2; return 0; fi

    # The digest check is three HEAD requests and belongs anywhere. The pull is
    # ~4 GB plus a squashfs build, so it belongs on a compute node.
    if (( force_local )) || [[ -n ${SLURM_JOB_ID:-} ]]; then
        sync_local "${STALE[@]}"
    else
        command -v sbatch >/dev/null || die "sbatch not found; re-run with --local inside an allocation"
        sync_sbatch "${STALE[@]}"
        if [[ -n $SYNC_JID ]]; then
            if (( do_watch )); then
                watch_job "$SYNC_JID"
            elif _tty; then
                local reply
                read -r -p "  Watch it? [y/N]: " reply </dev/tty
                [[ ${reply:-n} =~ ^[Yy] ]] && watch_job "$SYNC_JID"
            fi
        fi
    fi
}

main "$@"
