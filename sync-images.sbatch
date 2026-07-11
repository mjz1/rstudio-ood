#!/bin/bash
# sync-images.sbatch -- keep the RStudio .sif images in step with the registry
# automatically, on a monthly cadence, without cron.
#
# Cron is unavailable here (scrontab disabled cluster-wide, login-node crontab
# blocked by PAM), so this is a *self-resubmitting* Slurm job: each run does the
# sync, emails a summary, and submits the next run ~the 2nd of next month (just
# after rstudio-img's monthly rolling rebuild on the 1st). The email doubles as
# a heartbeat -- if you stop getting it, the chain broke.
#
# BOOTSTRAP (run once, from a login node -- this only *submits* a job, it does
# no compute here):
#     RSTUDIO_SYNC_EMAIL=you@example.com bash rstudio_dev/sync-images.sbatch
#   Add `--now` to also run an immediate sync in addition to scheduling monthly.
#
# Overridable via environment or the rstudio_dev config
# (~/.config/rstudio_dev/config); env wins:
#     RSTUDIO_SYNC_EMAIL       where to mail the summary (no email if unset)
#     RSTUDIO_SYNC_PARTITION   Slurm partition for the pull      (def cpushort)
#     RSTUDIO_SYNC_TIME/CPUS/MEM                                 (def 02:00:00/2/8G)
#     RSTUDIO_SYNC_LOGDIR      where run logs go   (def ~/work/.rstudio-img-sync)
#
#SBATCH --job-name=rstudio-img-sync
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G

set -uo pipefail

# --- resolve config (parsed, not sourced: the config has values with spaces) ---
CONFIG="${RSTUDIO_DEV_CONFIG:-$HOME/.config/rstudio_dev/config}"
cfg() { [ -r "$CONFIG" ] && grep -E "^$1=" "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }

EMAIL="${RSTUDIO_SYNC_EMAIL:-$(cfg RSTUDIO_SYNC_EMAIL)}"
PARTITION="${RSTUDIO_SYNC_PARTITION:-$(cfg RSTUDIO_SYNC_PARTITION)}"; PARTITION="${PARTITION:-cpushort}"
WALLTIME="${RSTUDIO_SYNC_TIME:-$(cfg RSTUDIO_SYNC_TIME)}"; WALLTIME="${WALLTIME:-02:00:00}"
CPUS="${RSTUDIO_SYNC_CPUS:-$(cfg RSTUDIO_SYNC_CPUS)}"; CPUS="${CPUS:-2}"
MEM="${RSTUDIO_SYNC_MEM:-$(cfg RSTUDIO_SYNC_MEM)}"; MEM="${MEM:-8G}"
LOGDIR="${RSTUDIO_SYNC_LOGDIR:-$(cfg RSTUDIO_SYNC_LOGDIR)}"; LOGDIR="${LOGDIR:-$HOME/work/.rstudio-img-sync}"
mkdir -p "$LOGDIR"

# Canonical path to *this* script, propagated across resubmissions. sbatch runs a
# spooled copy, so $0 inside the job is not the original -- carry it explicitly.
SELF="${RSTUDIO_SYNC_SELF:-$(readlink -f "$0")}"
SYNC="$(dirname "$SELF")/sync-images.sh"

# When to run next: 06:00 on the 2nd of next month (after the 1st-of-month rebuild).
next_begin() { date -d "$(date +%Y-%m-01) +1 month +1 day 06:00" +%Y-%m-%dT%H:%M:%S; }

submit() { # $1 = --begin value ("" for now)
  # Refuse to stack duplicates: if a sync job is already pending/running, skip.
  if squeue -h -u "$USER" -o '%j %t' 2>/dev/null | grep -q '^rstudio-img-sync'; then
    echo "a rstudio-img-sync job is already queued/running; not submitting another" >&2
    return 0
  fi
  local begin=(); [ -n "${1:-}" ] && begin=(--begin="$1")
  local mail=(); [ -n "$EMAIL" ] && mail=(--mail-type=FAIL --mail-user="$EMAIL")
  sbatch --parsable \
    --job-name=rstudio-img-sync \
    --partition="$PARTITION" --time="$WALLTIME" \
    --cpus-per-task="$CPUS" --mem="$MEM" \
    --output="$LOGDIR/sync-%j.log" \
    --export=ALL,RSTUDIO_SYNC_SELF="$SELF",RSTUDIO_SYNC_EMAIL="$EMAIL" \
    "${begin[@]}" "${mail[@]}" \
    "$SELF"
}

# =====================================================================
# BOOTSTRAP MODE: invoked as a plain script (not inside a Slurm job).
# Only submits jobs -- safe on a login node.
# =====================================================================
if [ -z "${SLURM_JOB_ID:-}" ]; then
  command -v sbatch >/dev/null || { echo "sbatch not found" >&2; exit 1; }
  [ -x "$SYNC" ] || { echo "sync-images.sh not found next to this script ($SYNC)" >&2; exit 1; }
  [ -n "$EMAIL" ] || echo "note: RSTUDIO_SYNC_EMAIL unset -- runs will log to $LOGDIR but send no email" >&2

  if [ "${1:-}" = "--now" ]; then
    echo "submitting an immediate sync..."
    jid=$(submit "") && echo "  immediate sync job: $jid"
  fi
  when="$(next_begin)"
  echo "scheduling next monthly sync for $when ..."
  jid=$(submit "$when") && echo "  scheduled job: $jid  (partition $PARTITION)"
  exit 0
fi

# =====================================================================
# JOB MODE: running inside the Slurm allocation -- do the actual work.
# =====================================================================
STAMP="$(date +%F' '%T)"
echo "==> rstudio-img sync starting $STAMP on $(hostname) (job $SLURM_JOB_ID)"

# --local: pull inline, in THIS allocation (we are already a compute job).
SUMMARY="$("$SYNC" --sync --local 2>&1)"; RC=$?
echo "$SUMMARY"
echo "==> sync-images.sh exited $RC"

# Email the summary (best-effort; the cluster MTA must deliver externally).
if [ -n "$EMAIL" ] && command -v mail >/dev/null 2>&1; then
  subject="[rstudio-img] monthly sync $(date +%F) -- $([ $RC -eq 0 ] && echo OK || echo FAILED rc=$RC)"
  printf '%s\n\nrc=%s  host=%s  job=%s\n' "$SUMMARY" "$RC" "$(hostname)" "$SLURM_JOB_ID" \
    | mail -s "$subject" "$EMAIL" \
    && echo "==> emailed summary to $EMAIL" \
    || echo "==> WARNING: mail to $EMAIL failed (check the log at $LOGDIR)"
fi

# Reschedule next month regardless of this run's result -- a transient failure
# should not stop the chain. (A hard failure before this line does stop it; the
# --mail-type=FAIL notification is the guard.)
echo "==> scheduling next month's run..."
submit "$(next_begin)"

exit "$RC"
