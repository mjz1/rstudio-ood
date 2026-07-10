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

        case "$key" in
            RSTUDIO_IMAGE_DIR|R_LIBS_ROOT|RSTUDIO_VERSIONS|RSTUDIO_CLUSTER|RSTUDIO_QUEUE|RSTUDIO_SYNC_PARTITION) ;;
            *) continue ;;                       # ignore unknown keys, don't eval them
        esac

        # Only adopt the file's value if the variable is not already set.
        if [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$val"
        fi
        export "${key?}"
    done < "$f"
}

_rsd_load_conf
