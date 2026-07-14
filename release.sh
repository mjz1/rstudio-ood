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

# A changelog nobody is forced to write is a changelog that rots. The Unreleased
# section must say something -- if a release is worth cutting, it is worth one
# line telling users what they get.
echo "==> CHANGELOG must have Unreleased content"
unreleased="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep -v '^\s*$' || true)"
if [[ -z $unreleased || $unreleased == *"_Nothing yet._"* ]]; then
    echo "error: CHANGELOG.md [Unreleased] is empty -- describe the release first" >&2
    exit 1
fi

echo "==> roll CHANGELOG: [Unreleased] -> [$v]"
python3 - "$v" <<'PY'
import re, sys, datetime
v = sys.argv[1]
today = datetime.date.today().isoformat()
s = open('CHANGELOG.md').read()

# Rename Unreleased -> the version, and open a fresh empty Unreleased above it.
s = s.replace('## [Unreleased]\n',
              f'## [Unreleased]\n\n_Nothing yet._\n\n## [{v}] - {today}\n', 1)

# Link refs: point Unreleased at the new tag, add a compare link for this release.
prev = re.search(r'^\[(\d+\.\d+\.\d+)\]:', s[s.index('[Unreleased]:'):], re.M)
prev_v = prev.group(1) if prev else None
s = re.sub(r'^\[Unreleased\]: .*$',
           f'[Unreleased]: https://github.com/mjz1/rstudio-ood/compare/v{v}...HEAD', s, flags=re.M)
if prev_v:
    s = s.replace(f'[{prev_v}]: ',
                  f'[{v}]: https://github.com/mjz1/rstudio-ood/compare/v{prev_v}...v{v}\n[{prev_v}]: ', 1)
open('CHANGELOG.md', 'w').write(s)
print(f"  changelog rolled to {v} ({today})")
PY
git add CHANGELOG.md
git commit -q -m "changelog: roll [Unreleased] into v$v"
git push -q origin dev

echo "==> merge dev -> master, stamp VERSION=$v, tag v$v"
git checkout -q master
git pull -q origin master
git merge --no-ff -q dev -m "release v$v"
echo "$v" > VERSION
git add VERSION
git commit -q -m "v$v"
# index(), not a regex: "## [0.9.2]" used as an awk regex is a CHARACTER CLASS,
# so it matched nothing and v0.9.2 was tagged with an empty body.
notes="$(awk -v want="## [$v]" 'index($0, want)==1 {f=1;next} /^## \[/{f=0} f' CHANGELOG.md)"
git tag -a "v$v" -m "v$v" -m "$notes"
git push -q origin master --tags

# Publish a GitHub Release from the changelog section, so the "what changed"
# link in the update notice lands on a page that renders the notes. Optional:
# skipped without gh, and never fatal -- a release is the tag, not the web page.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s\n' "$notes" | gh release create "v$v" --title "v$v" --notes-file - >/dev/null 2>&1; then
        echo "==> published GitHub release v$v"
    else
        echo "    (gh release failed; the tag is the release of record)" >&2
    fi
fi

echo "==> sync dev with the release"
git checkout -q dev
git merge -q master
git push -q origin dev

echo
echo "released v$v."
echo "  deploy stable:  git switch master && ./install.sh --app-only && git switch dev"
echo "  (staging keeps deploying from dev)"
