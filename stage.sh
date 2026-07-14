#!/usr/bin/env bash
#
# stage.sh -- deploy the CURRENT git branch as its own OnDemand staging app.
#
#   ./stage.sh              deploy/refresh the staging app for this branch
#   ./stage.sh --list       staged apps: branch, version, when deployed
#   ./stage.sh --rm BRANCH  remove one branch's staging app (--all for all)
#   ./stage.sh --prune      remove staging apps whose branch no longer exists
#
# Branch -> app mapping: branch `feat/x` becomes ~/ondemand/dev/rstudio_stage_feat_x,
# listed in OnDemand as "RStudio Server (feat/x)". The stable app (rstudio_dev)
# is NOT part of this scheme: it deploys from main only, via
#   git switch main && ./install.sh --app-only && git switch dev
#
# All staged apps share the one config, the same image set, and the same session
# slots -- so a staged app can resume a real slot to test against real state.
# Corollary: do not run the SAME slot concurrently from two apps.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

BASE="$HOME/ondemand/dev"
PREFIX="rstudio_stage_"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

list_apps() {
    local d found=0
    for d in "$BASE"/${PREFIX}*/; do
        [[ -d $d ]] || continue
        found=1
        local branch="?" ver="?"
        [[ -r $d/.staged-branch ]] && branch="$(cat "$d/.staged-branch")"
        [[ -r $d/.deployed-version ]] && ver="$(cat "$d/.deployed-version")"
        printf '  %-28s branch=%-20s %s\n' "$(basename "$d")" "$branch" "$ver"
    done
    (( found )) || echo "  (no staged apps)"
}

case "${1:-deploy}" in
    --list)
        list_apps ;;
    --rm)
        arg="${2:?usage: ./stage.sh --rm BRANCH | --all}"
        if [[ $arg == --all ]]; then
            rm -rf "$BASE"/${PREFIX}*/
            echo "removed all staged apps"
        else
            d="$BASE/${PREFIX}$(sanitize "$arg")"
            [[ -d $d ]] || { echo "no staged app for '$arg' ($d)" >&2; exit 1; }
            rm -rf "$d"
            echo "removed $d"
        fi ;;
    --prune)
        for d in "$BASE"/${PREFIX}*/; do
            [[ -r $d/.staged-branch ]] || continue
            b="$(cat "$d/.staged-branch")"
            if ! git show-ref -q --verify "refs/heads/$b"; then
                rm -rf "$d"
                echo "pruned $(basename "$d") (branch '$b' no longer exists)"
            fi
        done
        echo "prune complete"; list_apps ;;
    deploy)
        branch="$(git branch --show-current)"
        [[ -n $branch ]] || { echo "error: detached HEAD; check out a branch" >&2; exit 1; }
        if [[ $branch == main ]]; then
            echo "error: main deploys to the STABLE app, not a staging one:" >&2
            echo "       git switch main && ./install.sh --app-only && git switch dev" >&2
            exit 1
        fi
        dir="$BASE/${PREFIX}$(sanitize "$branch")"
        ./install.sh --app-only --app-dir "$dir" --app-name "RStudio Server ($branch)" >/dev/null
        printf '%s\n' "$branch" > "$dir/.staged-branch"
        echo "staged '$branch' -> $(basename "$dir")  (\"RStudio Server ($branch)\")"
        echo "  version: $(cat "$dir/.deployed-version" 2>/dev/null || echo '?')" ;;
    *)
        echo "usage: ./stage.sh [--list | --rm BRANCH|--all | --prune]" >&2; exit 1 ;;
esac
