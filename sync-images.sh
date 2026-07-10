#!/usr/bin/env bash
#
# sync-images.sh -- keep the RStudio Singularity images on this cluster in step
# with the container images published by https://github.com/mjz1/rstudio-img
#
# The registry is the source of truth. Every local image carries a `.digest`
# sidecar recording the registry manifest digest it was pulled from, so drift is
# detected with three HTTP HEAD requests instead of a 4 GB download.
#
#   sync-images.sh                  check only -- cheap, safe on a login node
#   sync-images.sh --sync           pull stale images (submits an sbatch job)
#   sync-images.sh --sync --local   pull inline, for use inside an allocation
#   sync-images.sh --sync 4.6       restrict to specific R versions
#   sync-images.sh --manifest       rebuild images.json from what is on disk
#
# Images are rolled in place but the previous build is retained as
# `rstudio-<ver>.sif.prev` (a hardlink, so it costs no extra disk until the new
# image lands). Rollback is therefore a rename, not a re-pull.
#
# Configuration, all overridable from the environment:
#
#   RSTUDIO_IMAGE_DIR   where .sif files live         (shared artifact)
#   R_LIBS_ROOT         where R package libraries live (per-user)
#   RSTUDIO_VERSIONS    space-separated R minor versions to track
#
set -euo pipefail

# Config file written by install.sh; environment still wins over it.
# shellcheck source=conf.sh
[ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/conf.sh" ] \
    && . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/conf.sh"

IMAGE_DIR="${RSTUDIO_IMAGE_DIR:-$HOME/work/images/rstudio}"
R_LIBS_ROOT="${R_LIBS_ROOT:-$HOME/work/R/x86_64-pc-linux-gnu-library}"
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

die()  { printf 'sync-images: %s\n' "$*" >&2; exit 1; }
log()  { printf '%s\n' "$*" >&2; }

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
    r=$(singularity exec "$sif" R --version 2>/dev/null | sed -nE '1s/^R version ([0-9.]+).*/\1/p') || true
    rstudio=$(singularity exec "$sif" rstudio-server version 2>/dev/null | awk 'NR==1{print $1}') || true
    quarto=$(singularity exec "$sif" quarto --version 2>/dev/null | head -1) || true
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
    export SINGULARITY_CACHEDIR="${SINGULARITY_CACHEDIR:-$HOME/work/.cache/singularity}"
    mkdir -p "$SINGULARITY_CACHEDIR"

    log "==> R $ver: pulling $ref@$(short "$digest")"
    singularity pull --disable-cache "$tmp" "docker://${ref}@${digest}" >&2

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
}

# --- commands -----------------------------------------------------------------

# Populates STALE[] with versions whose local digest != registry digest.
declare -a STALE=()
declare -A REMOTE_DIGEST=() REMOTE_REF=()

check() {
    local ver loc rem ref line
    printf '%-6s  %-12s  %s\n' "R" "STATUS" "DETAIL"
    for ver in "${VERSIONS[@]}"; do
        if ! line=$(registry_digest "$ver"); then
            printf '%-6s  %-12s  %s\n' "$ver" "UNREACHABLE" "no digest from either registry"
            continue
        fi
        rem=${line%% *}; ref=${line##* }
        REMOTE_DIGEST[$ver]=$rem; REMOTE_REF[$ver]=$ref
        loc=$(local_digest "$ver")

        if [[ ! -e $IMAGE_DIR/rstudio-$ver.sif ]]; then
            STALE+=("$ver")
            printf '%-6s  %-12s  %s\n' "$ver" "MISSING" "$(short "$rem")"
        elif [[ -z $loc ]]; then
            STALE+=("$ver")
            printf '%-6s  %-12s  %s\n' "$ver" "UNKNOWN" "no .digest sidecar; will re-pull"
        elif [[ $loc != "$rem" ]]; then
            STALE+=("$ver")
            printf '%-6s  %-12s  %s\n' "$ver" "STALE" "$(short "$loc") -> $(short "$rem")"
        else
            local detail="$(short "$rem")"
            if [[ -r $IMAGE_DIR/rstudio-$ver.sif.info ]]; then
                # %-format, not an f-string: this cluster's python3 is 3.6.
                detail+=" $(python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("(R %s, RStudio %s)" % (i["r_full"], i["rstudio"]))' "$IMAGE_DIR/rstudio-$ver.sif.info" 2>/dev/null || true)"
            fi
            printf '%-6s  %-12s  %s\n' "$ver" "up to date" "$detail"
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
    log "submitted job $jid to pull: $*"
    log "  log:   $LOGDIR/sync-$jid.log"
    log "  watch: squeue -j $jid"
}

usage() { sed -n '2,28p' "$SELF" | sed 's/^#\s\?//'; }

main() {
    local do_sync=0 force_local=0 do_manifest=0
    local -a want=()
    while (( $# )); do
        case "$1" in
            --sync)     do_sync=1 ;;
            --local)    force_local=1 ;;
            --check)    do_sync=0 ;;
            --manifest) do_manifest=1 ;;
            -h|--help)  usage; return 0 ;;
            -*)         die "unknown option: $1 (try --help)" ;;
            *)          want+=("$1") ;;
        esac
        shift
    done
    (( ${#want[@]} )) && VERSIONS=("${want[@]}")

    [[ -d $IMAGE_DIR ]] || die "image dir not found: $IMAGE_DIR"
    command -v singularity >/dev/null || die "singularity not on PATH"

    # Covers `die` inside pull_one, which exits rather than returning.
    trap 'rm -f "$IMAGE_DIR"/.rstudio-*.'"$$"'.partial.sif' EXIT

    if (( do_manifest )); then rebuild_manifest; return 0; fi

    check
    (( do_sync )) || return 0

    if (( ${#STALE[@]} == 0 )); then log "==> nothing to do"; return 0; fi

    # The digest check is three HEAD requests and belongs anywhere. The pull is
    # ~4 GB plus a squashfs build, so it belongs on a compute node.
    if (( force_local )) || [[ -n ${SLURM_JOB_ID:-} ]]; then
        sync_local "${STALE[@]}"
    else
        command -v sbatch >/dev/null || die "sbatch not found; re-run with --local inside an allocation"
        sync_sbatch "${STALE[@]}"
    fi
}

main "$@"
