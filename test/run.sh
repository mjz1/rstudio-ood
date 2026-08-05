#!/usr/bin/env bash
#
# run.sh -- render the ERB templates and check the result.
#
#   test/run.sh
#
# "There is no ruby on the cluster" was treated as a hard limit for a long time,
# which left the riskiest files in the app -- the ones OnDemand executes inside
# the PUN, where a mistake is a session that will not start -- as the only ones
# with no local test. But this app already depends on a container runtime. Ruby is
# a 40 MB image and three seconds away.
#
# So: use the host's ruby if it has one (GitHub Actions does), otherwise pull a
# ruby container and use that (the cluster). Same tests either way.
#
# The rendered output is then syntax-checked with the HOST's bash, which is the
# bash that will actually run the job script.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(dirname "$HERE")"

# Read the config in a SUBSHELL and take only the two values needed to find a
# ruby. Sourcing conf.sh here would export the whole of the developer's real
# config -- image dir, partitions, cluster -- into the environment, and the ERB
# templates prefer the environment over their config file. The tests would then
# quietly read this machine's cluster instead of the fixture. (erb_test.rb scrubs
# RSTUDIO_* as well; belt and braces, because this failure mode is invisible: it
# looks like passing tests.)
_conf() { ( [ -r "$APP/conf.sh" ] && . "$APP/conf.sh" >/dev/null 2>&1; printf '%s' "${!1:-}" ); }
RUBY_IMAGE="${RSTUDIO_TEST_RUBY_IMAGE:-docker://ruby:3-alpine}"
RUBY_SIF="${RSTUDIO_TEST_RUBY_SIF:-$(_conf RSTUDIO_WORK_DIR)/.cache/ruby-erb.sif}"
[ "$RUBY_SIF" = "/.cache/ruby-erb.sif" ] && RUBY_SIF="$HOME/.cache/rstudio-ood/ruby-erb.sif"
SINGULARITY="$(_conf RSTUDIO_SINGULARITY)"; SINGULARITY="${SINGULARITY:-singularity}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# --- find a ruby ---------------------------------------------------------------

if command -v ruby >/dev/null 2>&1; then
    ruby_run() { ruby "$@"; }
    echo "ruby: $(ruby --version)"
elif command -v "$SINGULARITY" >/dev/null 2>&1; then
    if [ ! -e "$RUBY_SIF" ]; then
        echo "No ruby on this host. Pulling one ($RUBY_IMAGE, ~40 MB, once)..."
        mkdir -p "$(dirname "$RUBY_SIF")"
        # --disable-cache: this is pulled once and never again; the blob cache
        # would just double the disk it costs.
        "$SINGULARITY" pull --disable-cache "$RUBY_SIF" "$RUBY_IMAGE" >/dev/null 2>&1 \
            || { echo "error: could not pull $RUBY_IMAGE" >&2; exit 1; }
    fi
    # Bind the RESOLVED app path. A checkout under ~/work is reached through a
    # symlink onto large storage, and binding the symlinked path gives the
    # container a link pointing at something it cannot see.
    APP="$(readlink -f "$APP")"
    HERE="$(readlink -f "$HERE")"
    # The fixture lives in the container's own $TMPDIR, so the tests touch
    # nothing real.
    ruby_run() {
        "$SINGULARITY" exec -B "$APP:$APP" -B "$OUT:$OUT" \
            --env "ERB_TEST_OUT=$OUT" "$RUBY_SIF" ruby "$@"
    }
    echo "ruby: $("$SINGULARITY" exec "$RUBY_SIF" ruby --version) (container: $RUBY_SIF)"
else
    echo "error: need either ruby on PATH or singularity/apptainer to run one" >&2
    exit 1
fi

# --- render + assert -----------------------------------------------------------

echo
ERB_TEST_OUT="$OUT" ruby_run "$HERE/erb_test.rb"

# --- the rendered job script must be valid bash --------------------------------
#
# Checked with the host's bash, not the container's: this is the shell that will
# actually run the job script on the compute node.

echo
echo 'rendered output'
rc=0
# Every script*.sh the suite wrote: the default render plus variants (e.g. the
# agent-access/MCP render), so a branch only taken under a form option cannot
# ship a bash syntax error the default render never exercises.
for s in "$OUT"/script*.sh; do
    name="$(basename "$s")"
    if bash -n "$s"; then
        echo "  ok   $name renders to syntactically valid bash"
    else
        echo "  FAIL $name renders to bash that will not parse"
        rc=1
    fi

    # The generated rsession wrapper is a heredoc inside the job script -- a
    # quoting mistake there produces a script that parses but writes a broken
    # wrapper, and the session dies with no output. Pull it out and check it too.
    if sed -n '/^  #!\/usr\/bin\/env bash/,/^EOL$/p' "$s" | sed 's/^  //; /^EOL$/d' > "$OUT/rsession-$name" \
       && [ -s "$OUT/rsession-$name" ]; then
        if bash -n "$OUT/rsession-$name"; then
            echo "  ok   the rsession wrapper $name writes is valid bash too"
        else
            echo "  FAIL the rsession wrapper $name writes will not parse"
            rc=1
        fi
    fi
done

# --- the sync canary must launch rserver the way the app does -------------------
#
# sync-images.sh test-launches a freshly pulled image before promoting it, with
# an rserver invocation that MIRRORS script.sh.erb's. Two copies drift: a flag
# added to one and not the other makes the canary vouch for a launch the app
# does not perform (or vice versa). Pin them together by extracting the flag
# names from each rserver block and diffing.
echo
echo 'sync canary flag parity'
_rserver_flags() { # _rserver_flags <file>
    # Flag name PLUS value when the value is a bare literal: literal values
    # must agree across the two files (--www-address=0.0.0.0 -- the value is
    # the whole point), while values that are legitimately local (paths,
    # ports, users) are always quoted/expanded, start with a quote or $, and
    # reduce to the bare flag name. The trailing `|| true` matters: with no
    # match, grep's nonzero + pipefail would abort the whole test script at
    # the assignment, swallowing the FAIL diagnostic below -- the [ -n ]
    # guard reports the empty set instead.
    sed -n '/ rserver \\$/,/--rsession-path/p' "$1" \
        | grep -oE '\-\-[a-z][a-z0-9-]+(=[^"$ \\]+)?' | sort -u || true
}
app_flags="$(_rserver_flags "$APP/template/script.sh.erb")"
canary_flags="$(_rserver_flags "$APP/sync-images.sh")"
if [ -n "$app_flags" ] && [ "$app_flags" = "$canary_flags" ]; then
    echo '  ok   sync-images.sh canary passes the same rserver flags as script.sh.erb'
else
    echo '  FAIL rserver flag drift between script.sh.erb (<) and sync-images.sh (>):'
    diff <(printf '%s\n' "$app_flags") <(printf '%s\n' "$canary_flags") | sed 's/^/       /' || true
    rc=1
fi

exit $rc
