#!/usr/bin/env bash
#==============================================================================
# daily_job_status_report.sh
#------------------------------------------------------------------------------
# Purpose : Read a catalogue of DataStage master sequences, query each job for
#           its run metadata + status, RAG colour-code the result, and produce a
#           daily HTML status report (emailed in production). Pure shell
#           automation - no AI/ML needed.
#
# Author  : Pavan Tummala
#
# Two run modes (auto-detected):
#   PROD  - when the DataStage `dsjob` CLI is on PATH: queries the engine and
#           emails the report via `sendmail`.
#   DEMO  - otherwise: uses the bundled sample config + canned engine responses
#           so the script runs on any machine and writes the HTML report to
#           ./output/job_status_report.html (this reproduces the README mockup).
#   Force a mode with  DEMO=1  or  DEMO=0.
#
# Usage   : ./daily_job_status_report.sh              # write HTML report to file
#           ./daily_job_status_report.sh --send       # also email it (prod)
#           ONLY_JOB=Job_C ./daily_job_status_report.sh   # single job
#
# Config  : config/jobmonitor.cfg   id|job|run_days|plan_start|plan_end|project|grp|service|info
#           config/token.cfg        job|project|token|info
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 1. CONFIGURATION (env-overridable; the only block you change per environment)
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOB_CONFIG="${JOB_CONFIG:-$SCRIPT_DIR/config/jobmonitor.cfg}"
TOKEN_CONFIG="${TOKEN_CONFIG:-$SCRIPT_DIR/config/token.cfg}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
OUTPUT_HTML="$OUTPUT_DIR/job_status_report.html"

DS_SERVER="${DS_SERVER:-:NNNNN}"               # DataStage engine host:port
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/data/edw/archive}"
MAIL_FROM="${MAIL_FROM:-ops.support@example.com}"
MAIL_TO="${MAIL_TO:-john.smith@example.com}"

# RAG palette (re-used by the HTML email)
COLOR_OK="#98FB98"        # green  - completed / on track / running
COLOR_WARN="#F4FA58"      # yellow - needs attention (e.g. compile issue)
COLOR_ALERT="#FFA07A"     # salmon - aborted / delayed / on hold
COLOR_DELAY="#FFE4B5"     # amber  - slightly delayed (legend only)
COLOR_UNKNOWN="orange"    # fallback

RUN_DATE=$(date '+%d-%m-%Y'); RUN_TIME=$(date '+%T')

#------------------------------------------------------------------------------
# 2. Mode detection + DataStage environment
#------------------------------------------------------------------------------
DEMO="${DEMO:-auto}"
if [ "$DEMO" = "auto" ]; then
  if command -v dsjob >/dev/null 2>&1; then DEMO=0; else DEMO=1; fi
fi
if [ "$DEMO" = "0" ]; then DSHOME=$(cat /.dshome); . "$DSHOME/dsenv"; fi

SEND_MAIL=0; [ "${1:-}" = "--send" ] && SEND_MAIL=1

#------------------------------------------------------------------------------
# 3. DataStage CLI wrappers. In DEMO mode these return canned output so the real
#    parsing + colour-coding logic below runs unchanged on any machine.
#------------------------------------------------------------------------------
demo_jobinfo() {                          # $1 = job -> "Job Status : LABEL (code)"
  case "$1" in
    Job_A|Source_X|Source_Y) code="RUN OK (1)" ;;
    Job_B)                   code="RUN OK with warnings (2)" ;;
    Job_C)                   code="RUNNING (0)" ;;
    Job_D|Source_Z)          code="ABORTED (3)" ;;
    Job_E)                   code="COMPILED (12)" ;;
    Job_F)                   code="NOT RUNNING (21)" ;;
    *)                       code="UNKNOWN (-1)" ;;
  esac
  printf 'Job Status   : %s\n' "$code"
}
demo_report() {                           # $1 = job -> start/end/elapsed lines
  case "$1" in
    Job_A) s="2026-06-18 02:03:00"; e="2026-06-18 04:11:00" ;;
    Job_B) s="2026-06-18 03:00:00"; e="2026-06-18 05:42:00" ;;
    Job_C) s="2026-06-18 04:34:00"; e="" ;;
    Job_D) s="2026-06-18 05:02:00"; e="" ;;
    Job_E) s="2026-06-18 05:30:00"; e="" ;;
    Job_F) s="2026-06-18 06:15:00"; e="" ;;
    *)     s=""; e="" ;;
  esac
  printf 'Job start time=%s\nJob end time=%s\nJob elapsed time=%s\n' "$s" "$e" "00:00:00"
}
ds_report()  { if [ "$DEMO" = "1" ]; then demo_report "$2";  else "$DSHOME/bin/dsjob" -server "$DS_SERVER" -report  "$1" "$2" 2>/dev/null; fi; }
ds_jobinfo() { if [ "$DEMO" = "1" ]; then demo_jobinfo "$2"; else "$DSHOME/bin/dsjob" -server "$DS_SERVER" -jobinfo "$1" "$2" 2>/dev/null; fi; }

#------------------------------------------------------------------------------
# 4. map_status - one DataStage status code -> label + colour (single source of
#    truth; the original repeated this in two places).
#------------------------------------------------------------------------------
map_status() {                            # $1 = numeric status code
  case "$1" in
    1|2)         job_status="Completed"     ; color=$COLOR_OK      ;;
    0)           job_status="In Progress"   ; color=$COLOR_OK      ;;
    3|96|97)     job_status="Aborted"       ; color=$COLOR_ALERT   ;;
    9|11|21|99)  job_status="Yet to Start"  ; color=$COLOR_OK      ;;
    8|12|13|19)  job_status="Compile Issue" ; color=$COLOR_WARN    ;;
    *)           job_status="Unknown"       ; color=$COLOR_UNKNOWN ;;
  esac
}

fmt_time() {                              # "YYYY-MM-DD HH:MM:SS" -> "HH:MM" (else ---)
  case "$1" in ""|"---") printf '%s' "---" ;; *) printf '%s' "$1" | awk '{print $2}' | cut -c1-5 ;; esac
}

#------------------------------------------------------------------------------
# 5. get_run_metadata - ONE report call per job (the original made three), parse
#    status in the same pass, and keep the raw start time for the date logic.
#------------------------------------------------------------------------------
get_run_metadata() {                      # $1 = project   $2 = job
  report=$(ds_report "$1" "$2")
  raw_srt=$(printf '%s\n' "$report" | awk -F'=' '/Job start time/   {print $2; exit}')
  raw_end=$(printf '%s\n' "$report" | awk -F'=' '/Job end time/     {print $2; exit}')

  status_raw=$(ds_jobinfo "$1" "$2" | awk -F':' '/Job Status/ {print $2; exit}')
  status_num=$(printf '%s' "$status_raw" | sed 's/.*(\(-*[0-9]*\)).*/\1/')
  map_status "$status_num"

  act_start=$(fmt_time "$raw_srt")
  completion=$(fmt_time "$raw_end")
  # Blank time fields that carry no meaning for the current status
  case "$job_status" in
    "In Progress"|"Aborted")        completion="---" ;;
    "Yet to Start"|"Compile Issue") act_start="---"; completion="---" ;;
  esac
}

#------------------------------------------------------------------------------
# 6. Processing date - two generic patterns instead of ~20 hard-coded job names:
#      Pattern A: from the source feed's landing file   (Job_A, Job_B)
#      Pattern B: from the job's own start time          (Job_C..Job_F)
#------------------------------------------------------------------------------
get_landing_date() {                      # $1 = source dir   $2 = file pattern
  [ "$DEMO" = "1" ] && { printf '20260618'; return; }
  ls -tr "$ARCHIVE_ROOT/$1" 2>/dev/null | grep -i "$2" | tail -1 | tr -dc '[:digit:]' | cut -c1-8
}
get_processing_date() {                   # $1 = job, uses $raw_srt
  case "$1" in
    Job_A) Processing_dt=$(get_landing_date "src_a" "FEED_A") ;;
    Job_B) Processing_dt=$(get_landing_date "src_b" "FEED_B") ;;
    *)     Processing_dt=$(printf '%s' "$raw_srt" | cut -c1-10 | tr -d '-') ;;
  esac
  [ -z "$Processing_dt" ] && Processing_dt="N/A"
}

#==============================================================================
# 7. Build one report row per master sequence
#==============================================================================
mkdir -p "$OUTPUT_DIR"
ROWS_FILE="$OUTPUT_DIR/.rows.psv"; : > "$ROWS_FILE"

while IFS='|' read -r f_id f_job f_days f_pstart f_pend f_proj f_grp f_service f_info; do
  case "$f_id" in ''|'#'*) continue ;; esac                 # skip blanks/comments
  [ -n "${ONLY_JOB:-}" ] && [ "$ONLY_JOB" != "$f_job" ] && continue
  get_run_metadata    "$f_proj" "$f_job"
  get_processing_date "$f_job"
  f_info=${f_info:-&mdash;}                                  # show a dash when no note
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${f_job//_/ }" "$Processing_dt" "$job_status" "$f_pstart" "$act_start" "$completion" "$f_info" "$color" \
    >> "$ROWS_FILE"
done < "$JOB_CONFIG"

#------------------------------------------------------------------------------
# 8. Build the catch-up / pending-batch rows (Batch 2 loads)
#------------------------------------------------------------------------------
if [ "$DEMO" = "0" ]; then
  PENDING=$(find "$ARCHIVE_ROOT"/TOKEN/*_STAGE_*.TOK 2>/dev/null | sed 's#.*/##; s/_STAGE_.*//')
fi
get_pending_count() {                      # $1 = token
  if [ "$DEMO" = "1" ]; then
    case "$1" in TOK_X) printf '0';; TOK_Y) printf '3';; TOK_Z) printf '1';; *) printf '0';; esac
  else
    printf '%s\n' "$PENDING" | grep -c "$1"
  fi
}

TOKEN_FILE="$OUTPUT_DIR/.tokens.psv"; : > "$TOKEN_FILE"
while IFS='|' read -r t_job t_proj t_token t_info; do
  case "$t_job" in ''|'#'*) continue ;; esac
  count=$(get_pending_count "$t_token")
  status_raw=$(ds_jobinfo "$t_proj" "$t_job" | awk -F':' '/Job Status/ {print $2; exit}')
  map_status "$(printf '%s' "$status_raw" | sed 's/.*(\(-*[0-9]*\)).*/\1/')"

  if   [ "$job_status" = "Completed" ] && [ "$count" -gt 0 ]; then job_status="Yet to Run"
  elif [ "$job_status" = "Completed" ] && [ "$count" -eq 0 ]; then job_status="Completed - no pending batches"
  fi
  t_info=${t_info:-&mdash;}                                  # show a dash when no note
  printf '%s|%s|%s|%s|%s\n' "${t_job//_/ }" "$count" "$job_status" "$t_info" "$color" >> "$TOKEN_FILE"
done < "$TOKEN_CONFIG"

#==============================================================================
# 9. Render the HTML report
#==============================================================================
TABLE_STYLE='style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:13px"'
HEAD='bgcolor="#1874CD"'

emit_table() {        # $1 = rows file, $2 = colour field index, $3.. = headers
  local file=$1 cidx=$2; shift 2
  printf '<table border="1" cellspacing="0" cellpadding="6" %s><tr>' "$TABLE_STYLE"
  for h in "$@"; do printf '<td align="center" %s><font color="white"><b>%s</b></font></td>' "$HEAD" "$h"; done
  printf '</tr>\n'
  while IFS='|' read -r -a c; do
    printf '<tr>'
    local n=$(( ${#c[@]} - 1 )) i
    for (( i=0; i<n; i++ )); do printf '<td bgcolor="%s">%s</td>' "${c[$cidx]}" "${c[$i]}"; done
    printf '</tr>\n'
  done < "$file"
  printf '</table>\n'
}

compose_body() {
  printf 'Hi All,<br><br>Please find below the daily status of all batches.<br><br>\n'
  # Legend
  printf '<table border="1" cellspacing="0" cellpadding="6" style="border-collapse:collapse;font-family:Segoe UI,Arial"><tr>'
  printf '<td align="center" bgcolor="%s"><b>ON TRACK</b></td>' "$COLOR_OK"
  printf '<td align="center" bgcolor="%s"><b>SLIGHTLY DELAYED</b></td>' "$COLOR_DELAY"
  printf '<td align="center" bgcolor="%s"><b>DELAYED / ON HOLD</b></td>' "$COLOR_ALERT"
  printf '</tr></table><br>\n'
  # Main table (colour = field index 7)
  printf '<b>Batch 1 Load Status</b><br><br>\n'
  emit_table "$ROWS_FILE" 7 "APPLICATION" "PROC DATE" "STATUS" "PLAN START" "ACTUAL START" "COMPLETION" "ADDITIONAL INFO"
  printf '<br><br><b>Batch 2 Load Status</b><br><br>\n'
  # Catch-up table (colour = field index 4)
  emit_table "$TOKEN_FILE" 4 "APPLICATION" "PENDING BATCHES" "STATUS" "ADDITIONAL INFO"
}

SUBJECT="Batch Load Status as on $RUN_DATE at $RUN_TIME"

# Write a standalone HTML file (always - so you can preview the output)
{
  printf '<html><body style="font-family:Segoe UI,Arial,sans-serif">\n'
  printf '<h3>%s</h3>\n' "$SUBJECT"
  compose_body
  printf '</body></html>\n'
} > "$OUTPUT_HTML"

echo "Report written to: $OUTPUT_HTML  (mode: $([ "$DEMO" = 1 ] && echo DEMO || echo PROD))"

# Email it in production (only if requested AND sendmail is available)
if [ "$SEND_MAIL" = "1" ] && command -v sendmail >/dev/null 2>&1; then
  {
    printf 'From: %s\nTo: %s\nMIME-Version: 1.0\nContent-Type: text/html\nSubject: %s\n\n' \
      "$MAIL_FROM" "$MAIL_TO" "$SUBJECT"
    printf '<html><body style="font-family:Segoe UI,Arial,sans-serif">\n'
    compose_body
    printf '</body></html>\n'
  } | sendmail -t -r "$MAIL_FROM"
  echo "Email sent to: $MAIL_TO"
elif [ "$SEND_MAIL" = "1" ]; then
  echo "sendmail not found - skipped emailing (HTML report still written)."
fi

# Tidy intermediate files
rm -f "$ROWS_FILE" "$TOKEN_FILE"
