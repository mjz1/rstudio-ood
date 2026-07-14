# shellcheck shell=bash
#
# Shared config loader for the bash side (sync-images.sh, r-wrappers.sh).
#
# Precedence: environment > config file > each script's own defaults. So an
# exported RSTUDIO_IMAGE_DIR always wins, which keeps one-off overrides working.
#
# The config file is written by install.sh and is also read by the OnDemand ERB
# templates, which run inside the PUN and do not reliably source your shell rc --
# that is why this is a file and not just environment variables.

_rsd_load_conf() {
    local f="${RSTUDIO_DEV_CONFIG:-$HOME/.config/rstudio_dev/config}"
    [ -r "$f" ] || return 0

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|'') continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        [ "$key" != "$line" ] || continue        # no '=' on the line
        key="${key//[[:space:]]/}"

        # Allowlist: the config file is data, never evaluated, so an unknown or
        # malicious key is ignored rather than becoming a variable. Keep this in
        # step with what install.sh writes.
        case "$key" in
            RSTUDIO_IMAGE_DIR|R_LIBS_ROOT|RSTUDIO_WORK_DIR|RSTUDIO_BIND_PATHS|RSTUDIO_APP_DIR) ;;
            RSTUDIO_VERSIONS|RSTUDIO_SYNC_ROLE|RSTUDIO_SINGULARITY) ;;
            RSTUDIO_CLUSTER|RSTUDIO_QUEUE|RSTUDIO_QUEUES|RSTUDIO_SYNC_PARTITION|RSTUDIO_TORCH_CUDA) ;;
            *) continue ;;
        esac

        # Only adopt the file's value if the variable is not already set.
        if [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$val"
        fi
        # Deliberately NOT exported. Sourcing this from a shell rc used to spray
        # a dozen variables (including the generically-named R_LIBS_ROOT) into
        # the environment of EVERYTHING the user runs -- other R setups
        # included, which is exactly the kind of interference this app promises
        # not to commit. Nothing needs the export: every consumer script sources
        # this file itself, and the values here are visible to functions defined
        # in the same shell (the wrappers) without it. A user's own `export
        # VAR=...` still wins, because the adopt above skips set variables.
    done < "$f"
}

_rsd_load_conf

# Defaults for installs that predate these keys: the historical hard-coded
# behaviour, so an old config file keeps working untouched.
: "${RSTUDIO_WORK_DIR:=$HOME/work}"
: "${RSTUDIO_SINGULARITY:=singularity}"
: "${RSTUDIO_BIND_PATHS:=/data1,/run/munge,/etc/slurm,/usr/lib64/slurm,/usr/lib64/libmunge.so.2}"

# Echo `-B <path>` arguments for each configured bind path that actually exists
# on THIS machine. A bind path that is missing makes singularity fail outright,
# so a site without /data1 (or a compute node without munge) must not inherit
# another site's list. `IFS=,` is a prefix assignment to `read` alone, so it does
# not leak into callers -- unlike `local IFS`, which is dynamically scoped.
_rsd_bind_args() {
    local b arr=()
    IFS=',' read -r -a arr <<<"${RSTUDIO_BIND_PATHS:-}"
    for b in "${arr[@]}"; do
        [ -n "$b" ] && [ -e "$b" ] && printf '%s\n%s\n' "-B" "$b"
    done
}
