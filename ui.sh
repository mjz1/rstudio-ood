# shellcheck shell=bash
#
# Shared terminal UI kit for install.sh and sync-images.sh.
#
# Colour and glyphs, degrading to plain text wherever a human is not watching a
# terminal: stderr not a TTY (piped, CI, logs, sbatch jobs), NO_COLOR set, or
# TERM=dumb. Glyphs additionally require a UTF-8 locale; otherwise ASCII
# stand-ins. The decoration is decoration only -- every message prints the same
# words either way, so logs stay grep-able.
#
# Sourced by absolute sibling path; scripts define plain fallbacks if this file
# is missing (people copy single scripts around), so it must never be required.

_ui_tty=0
[[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]] && _ui_tty=1
if (( _ui_tty )); then
    C_R=$'\033[0m'  C_B=$'\033[1m'  C_DIM=$'\033[2m'
    C_HDR=$'\033[1;36m'  C_OK=$'\033[32m'  C_WARN=$'\033[33m'  C_ERR=$'\033[31m'
else
    C_R='' C_B='' C_DIM='' C_HDR='' C_OK='' C_WARN='' C_ERR=''
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*8*) G_OK='✓' G_BAD='✗' G_WARN='!' G_RULE='─' G_DOT='·' ;;
    *)                G_OK='ok' G_BAD='x' G_WARN='!' G_RULE='-' G_DOT='/' ;;
esac

die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_R" "$*" >&2; exit 1; }
warn() { printf '%s%s warn:%s %s\n' "$C_WARN" "$G_WARN" "$C_R" "$*" >&2; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s%s%s %s\n' "$C_OK" "$G_OK" "$C_R" "$*"; }
bad()  { printf '  %s%s%s %s\n' "$C_ERR" "$G_BAD" "$C_R" "$*"; }
note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_R"; }
head2(){ printf '\n%s%s%s\n' "$C_B" "$1" "$C_R"; }

# say/dimsay write to STDERR so they can be used inside functions whose stdout
# is captured by a command substitution (interview helpers).
say()  { printf '  %s\n' "$*" >&2; }
dimsay(){ printf '  %s%s%s\n' "$C_DIM" "$*" "$C_R" >&2; }
blank(){ printf '\n' >&2; }

# The rule is built by repetition, NOT `tr ' ' "$G_RULE"`: tr is byte-wise and
# shreds a multibyte glyph into mojibake.
_rule() { local n="$1" out="" i; for ((i=0;i<n;i++)); do out+="$G_RULE"; done; printf '%s' "$out"; }

# Step header: "── Step 2 of 5 · Storage ──────". Set UI_STEPS before use.
UI_STEPS="${UI_STEPS:-5}"
step() {  # step <n> <title>
    printf '\n%s%s%s Step %s of %s %s %s %s%s\n' \
        "$C_HDR" "$(_rule 2)" "$C_R$C_B" "$1" "$UI_STEPS" "$G_DOT" "$2" "$C_R$C_DIM$(_rule 40)" "$C_R"
}
