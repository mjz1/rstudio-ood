#!/usr/bin/env bash
#
# release.sh X.Y.Z -- the ONLY way master moves.
#
# master is what `curl | bash` serves and what the update notice reads, so it
# must contain released code only. This script is the release: it verifies the
# suite on dev, merges dev into master, writes VERSION (which must always equal
# the latest tag -- so no hand edits), tags, pushes, and re-syncs dev.
#
#   ./release.sh 0.9.1
#
# Afterwards, deploy the stable app FROM master:
#   git switch master && ./install.sh --app-only && git switch dev
#
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

v="${1:?usage: ./release.sh X.Y.Z}"
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: '$v' is not X.Y.Z" >&2; exit 1; }
[[ -z $(git status --porcelain) ]]   || { echo "error: working tree not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$v" >/dev/null && { echo "error: v$v already exists" >&2; exit 1; }

echo "==> suite must be green on dev"
git checkout -q dev
git pull -q origin dev 2>/dev/null || true
./test/run.sh >/dev/null || { echo "error: test suite failed; not releasing" >&2; exit 1; }

echo "==> merge dev -> master, stamp VERSION=$v, tag v$v"
git checkout -q master
git pull -q origin master
git merge --no-ff -q dev -m "release v$v"
echo "$v" > VERSION
git add VERSION
git commit -q -m "v$v"
git tag -a "v$v" -m "v$v"
git push -q origin master --tags

echo "==> sync dev with the release"
git checkout -q dev
git merge -q master
git push -q origin dev

echo
echo "released v$v."
echo "  deploy stable:  git switch master && ./install.sh --app-only && git switch dev"
echo "  (staging keeps deploying from dev)"
