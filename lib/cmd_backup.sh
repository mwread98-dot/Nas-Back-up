#!/bin/sh
# lib/cmd_backup.sh -- the weekly run.
#
# The whole point of this command: `rclone sync` mirrors. One live copy in S3
# that tracks the NAS, plus a bounded window of superseded versions handled by
# bucket versioning + lifecycle. Unchanged bytes are never re-uploaded and
# never re-stored, which is the bug in the stock My Cloud S3 app.

NB_RUN_LOG=''
NB_DRY_RUN=false

# Set by backup_one_job, read by its helpers and by the run summary.
NB_DEST_OBJECTS=0
JOB_END_OBJECTS=0
JOB_END_BYTES=0
JOB_SECONDS=0

cmd_backup_usage() {
	cat <<'EOF'
Usage: nasbak backup [options]

  -j, --job NAME     Run only this backup set (repeatable).
  -n, --dry-run      Show what would change; transfer and delete nothing.
      --no-guard     Skip the --max-delete guard. Only after you have read the
                     dry-run output and agree with every deletion.
  -v, --verbose      Debug logging.
EOF
}

cmd_backup() {
	_only=''
	_no_guard=false

	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job)
			_only="$_only $2"
			shift 2
			;;
		-n | --dry-run)
			NB_DRY_RUN=true
			shift
			;;
		--no-guard)
			_no_guard=true
			shift
			;;
		-v | --verbose)
			NB_LOGLEVEL=0
			shift
			;;
		-h | --help)
			cmd_backup_usage
			return 0
			;;
		*)
			opt_error "$1" "${2:-}"
			cmd_backup_usage
			return 2
			;;
		esac
	done

	config_load
	config_validate
	config_dirs
	jobs_snapshot_globals
	rclone_require
	rclone_env

	_stamp=$(date '+%Y%m%d-%H%M%S')
	if [ "$NB_DRY_RUN" = true ]; then
		# A dry run is something you sit and watch. Keep it off disk so it
		# does not land in the log directory looking like a real run.
		NB_RUN_LOG=''
	else
		NB_RUN_LOG="$LOG_DIR/backup-$_stamp.log"
		NB_LOGFILE="$NB_RUN_LOG"
	fi

	if [ "$(jobs_count)" -eq 0 ]; then
		die "no backup sets defined in $JOBS_DIR. Run 'nasbak add-job --help'."
	fi

	lock_acquire "$LOCK_DIR" "$LOCK_STALE_AFTER" || return 1

	_t0=$(date +%s)
	[ "$NB_DRY_RUN" = false ] && hc_ping start

	info "nasbak backup starting (log: ${NB_RUN_LOG:-stderr only})"
	[ "$NB_DRY_RUN" = true ] && warn "DRY RUN: nothing will be uploaded or deleted"

	_failed=0
	_ran=0
	_skipped=0
	_tot_bytes=0
	_tot_objects=0
	_summary=''

	for _jf in $(jobs_list); do
		job_load "$_jf" || {
			_failed=$((_failed + 1))
			continue
		}

		if [ -n "$_only" ]; then
			case " $_only " in
			*" $JOB_NAME "*) : ;;
			*)
				debug "[$JOB_NAME] not selected"
				continue
				;;
			esac
		fi

		if [ "$JOB_ENABLED" != true ]; then
			info "[$JOB_NAME] disabled; skipping"
			_skipped=$((_skipped + 1))
			continue
		fi

		job_validate || {
			_failed=$((_failed + 1))
			continue
		}
		job_preflight || {
			_failed=$((_failed + 1))
			_summary="$_summary
  $JOB_NAME: FAILED preflight"
			continue
		}

		_ran=$((_ran + 1))
		if backup_one_job "$_no_guard"; then
			_summary="$_summary
  $JOB_NAME: ok, $(human_bytes "$JOB_END_BYTES") in $JOB_END_OBJECTS objects ($(human_duration "$JOB_SECONDS"))"
			_tot_bytes=$((_tot_bytes + JOB_END_BYTES))
			_tot_objects=$((_tot_objects + JOB_END_OBJECTS))
		else
			_failed=$((_failed + 1))
			_summary="$_summary
  $JOB_NAME: FAILED (see $NB_RUN_LOG)"
		fi
	done

	_t1=$(date +%s)
	_elapsed=$((_t1 - _t0))

	info "----------------------------------------------------------------"
	info "ran $_ran set(s), skipped $_skipped, failed $_failed in $(human_duration "$_elapsed")"
	info "stored: $(human_bytes "$_tot_bytes") across $_tot_objects objects"

	if [ "$NB_DRY_RUN" = false ]; then
		backup_write_state "$_t0" "$_t1" "$_ran" "$_failed" "$_tot_objects" "$_tot_bytes"
		log_rotate
	fi

	if [ "$_failed" -gt 0 ]; then
		[ "$NB_DRY_RUN" = false ] && hc_ping fail
		[ "$NOTIFY_ON" != never ] &&
			notify "NAS backup FAILED ($_failed set(s))" "Host: $(hostname 2>/dev/null)
Elapsed: $(human_duration "$_elapsed")
$_summary

Log: $NB_RUN_LOG"
		error "backup finished with $_failed failure(s)"
		return 1
	fi

	[ "$NB_DRY_RUN" = false ] && hc_ping
	if [ "$NOTIFY_ON" = always ] && [ "$NB_DRY_RUN" = false ]; then
		notify "NAS backup OK" "Host: $(hostname 2>/dev/null)
Elapsed: $(human_duration "$_elapsed")
Stored: $(human_bytes "$_tot_bytes") / $_tot_objects objects
$_summary"
	fi
	ok "backup complete"
	return 0
}

# ------------------------------------------------------------- single job ----

backup_one_job() {
	_boj_no_guard=$1
	_boj_dest=$(remote_path "$JOB_PREFIX")
	_boj_thresh=$(parse_size "$JOB_THRESHOLD")
	_boj_j0=$(date +%s)

	info "[$JOB_NAME] $JOB_SOURCE  ->  $_boj_dest"
	info "[$JOB_NAME] class=$JOB_CLASS small(<$(human_bytes "$_boj_thresh"))=$JOB_SMALL_CLASS compare=$COMPARE_MODE"

	# One LIST of the destination. It gives us the object count (for the
	# delete guard and for --fast-list sizing) and the stored bytes we report.
	# LIST is metadata only, so this is safe and cheap even against
	# DEEP_ARCHIVE.
	if ! _boj_before=$(rclone_size "$_boj_dest"); then
		error "[$JOB_NAME] could not read the destination listing from S3."
		error "[$JOB_NAME] refusing to sync without knowing what is already stored --"
		error "[$JOB_NAME] the deletion guard is sized from that number."
		error "[$JOB_NAME] run 'nasbak check' to find out why."
		return 1
	fi
	NB_DEST_OBJECTS=$(printf '%s' "$_boj_before" | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 0}')
	_boj_before_bytes=$(printf '%s' "$_boj_before" | awk '{print ($2 ~ /^[0-9]+$/) ? $2 : 0}')
	info "[$JOB_NAME] currently in S3: $NB_DEST_OBJECTS objects, $(human_bytes "$_boj_before_bytes")"

	# How many deletions we are willing to let through. Measured against what
	# is already backed up, because that is what a runaway sync would destroy.
	_boj_max_delete=$(backup_max_delete "$NB_DEST_OBJECTS")
	if [ "$_boj_no_guard" = true ]; then
		warn "[$JOB_NAME] delete guard disabled by --no-guard"
		_boj_max_delete=''
	else
		info "[$JOB_NAME] delete guard: abort if more than $_boj_max_delete object(s) would be removed"
	fi

	_boj_rc=0
	if [ "$JOB_SMALL_CLASS" = "$JOB_CLASS" ]; then
		# One class for everything: a single pass, no size filters.
		backup_sync_pass all "$JOB_CLASS" '' '' "$_boj_max_delete" "$_boj_dest" || _boj_rc=1
	else
		# Two passes over the same prefix with complementary size filters.
		#
		# Large first. rclone applies size filters to both sides of a sync, so
		# after the large pass has written a grown file the small pass no
		# longer sees it on either side and leaves it alone. Small-first would
		# delete the stale small object and re-upload, burning a delete against
		# the guard for no reason.
		#
		# The boundary is half-open: [threshold, inf) then [0, threshold-1],
		# so no object is claimed by both passes.
		backup_sync_pass large "$JOB_CLASS" "${_boj_thresh}B" '' "$_boj_max_delete" "$_boj_dest" || _boj_rc=1
		if [ "$_boj_rc" -eq 0 ]; then
			backup_sync_pass small "$JOB_SMALL_CLASS" '' "$((_boj_thresh - 1))B" "$_boj_max_delete" "$_boj_dest" || _boj_rc=1
		else
			warn "[$JOB_NAME] skipping the small-file pass because the large pass failed"
		fi
	fi

	_boj_after=$(rclone_size "$_boj_dest")
	JOB_END_OBJECTS=$(printf '%s' "$_boj_after" | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 0}')
	JOB_END_BYTES=$(printf '%s' "$_boj_after" | awk '{print ($2 ~ /^[0-9]+$/) ? $2 : 0}')
	_boj_j1=$(date +%s)
	JOB_SECONDS=$((_boj_j1 - _boj_j0))

	_boj_dobj=$((JOB_END_OBJECTS - NB_DEST_OBJECTS))
	_boj_dbytes=$((JOB_END_BYTES - _boj_before_bytes))
	info "[$JOB_NAME] now in S3: $JOB_END_OBJECTS objects, $(human_bytes "$JOB_END_BYTES") (delta: $_boj_dobj objects, $_boj_dbytes bytes)"

	if [ "$_boj_rc" -eq 0 ]; then
		ok "[$JOB_NAME] done in $(human_duration "$JOB_SECONDS")"
		backup_churn_warning "$_boj_before_bytes" "$_boj_dbytes"
	else
		error "[$JOB_NAME] failed after $(human_duration "$JOB_SECONDS")"
	fi
	return "$_boj_rc"
}

backup_sync_pass() {
	_bsp_label=$1
	_bsp_class=$2
	_bsp_minsize=$3
	_bsp_maxsize=$4
	_bsp_maxdel=$5
	_bsp_dest=$6

	info "[$JOB_NAME] pass '$_bsp_label' -> $_bsp_class"

	argv_reset
	argv_add sync "$JOB_SOURCE" "$_bsp_dest"
	argv_add --s3-storage-class "$_bsp_class"
	argv_add_common
	argv_add_compare
	argv_add_fast_list "$NB_DEST_OBJECTS"
	argv_add_filters "$JOB_EXCLUDES"

	[ -n "$_bsp_minsize" ] && argv_add --min-size "$_bsp_minsize"
	[ -n "$_bsp_maxsize" ] && argv_add --max-size "$_bsp_maxsize"
	[ -n "$JOB_BWLIMIT" ] && argv_add --bwlimit "$JOB_BWLIMIT"

	# --delete-after, not the default --delete-during: it makes rclone settle
	# the full deletion list before removing anything, so --max-delete aborts
	# the run *before* the first object disappears rather than partway through.
	argv_add --delete-after
	[ -n "$_bsp_maxdel" ] && argv_add --max-delete "$_bsp_maxdel"

	# Keep superseded and deleted objects visible under a dated prefix instead
	# of relying on bucket versioning. Off by default; see docs/COSTS.md.
	if [ "${BACKUP_DIR_MODE:-false}" = true ]; then
		argv_add --backup-dir "$(remote_path "_versions/$(date '+%Y-%m-%d')/$JOB_PREFIX")"
	fi

	[ "$NB_DRY_RUN" = true ] && argv_add --dry-run --verbose

	rclone_run
	_pass_rc=$?
	if [ "$_pass_rc" -ne 0 ]; then
		# rclone exit 9 means "nothing was transferred", which only happens
		# under --error-on-no-transfer. We do not set it, but treat it as
		# success anyway: an unchanged backup set is the normal case.
		if [ "$_pass_rc" -eq 9 ]; then
			info "[$JOB_NAME] pass '$_bsp_label': nothing to transfer"
			return 0
		fi
		error "[$JOB_NAME] pass '$_bsp_label' exited $_pass_rc"
		return 1
	fi
	return 0
}

# max(MAX_DELETE_ABS, pct of what is stored), floored at 10 so a small or
# freshly-seeded backup set is not permanently blocked by rounding.
backup_max_delete() {
	_bmd_objects=$1
	_bmd_pct=$JOB_MAX_DELETE_PCT
	is_uint "$_bmd_pct" || _bmd_pct=5
	_bmd_from_pct=$(((_bmd_objects * _bmd_pct + 99) / 100))
	_bmd_val=$_bmd_from_pct
	if is_uint "$JOB_MAX_DELETE_ABS" && [ "$JOB_MAX_DELETE_ABS" -gt "$_bmd_val" ]; then
		_bmd_val=$JOB_MAX_DELETE_ABS
	fi
	[ "$_bmd_val" -lt 10 ] && _bmd_val=10
	printf '%s' "$_bmd_val"
}

# Archive classes bill a minimum storage duration. Re-uploading the same file
# every week into DEEP_ARCHIVE means paying 180 days for each weekly copy --
# roughly 25x the sticker price. Say so when the numbers start to look like
# that.
backup_churn_warning() {
	_bcw_stored=$1
	_bcw_delta=$2
	_bcw_min=$(class_min_days "$JOB_CLASS")
	[ "$_bcw_min" -le 30 ] && return 0
	[ "$_bcw_stored" -le 0 ] && return 0
	[ "$_bcw_delta" -lt 0 ] && _bcw_delta=$((0 - _bcw_delta))
	# Rewriting more than a tenth of the set every run is churn, not a backup.
	_bcw_tenth=$((_bcw_stored / 10))
	if [ "$_bcw_delta" -gt "$_bcw_tenth" ] && [ "$_bcw_delta" -gt 1073741824 ]; then
		warn "[$JOB_NAME] this run changed $(human_bytes "$_bcw_delta") of $(human_bytes "$_bcw_stored") stored."
		warn "[$JOB_NAME] $JOB_CLASS has a ${_bcw_min}-day minimum billing duration, so data that"
		warn "[$JOB_NAME] churns this fast is billed several times over. Consider GLACIER_IR"
		warn "[$JOB_NAME] or STANDARD for this set, or split the volatile directories out."
	fi
}

# ----------------------------------------------------------------- state -----

backup_write_state() {
	_t0=$1 _t1=$2 _ran=$3 _failed=$4 _objects=$5 _bytes=$6
	_status=ok
	[ "$_failed" -gt 0 ] && _status=failed

	write_atomic "$STATE_DIR/last-run" <<EOF
started=$_t0
finished=$_t1
status=$_status
jobs_run=$_ran
jobs_failed=$_failed
objects=$_objects
bytes=$_bytes
log=$NB_RUN_LOG
EOF

	write_atomic "$STATE_DIR/last-run.json" <<EOF
{
  "started": $_t0,
  "finished": $_t1,
  "started_utc": "$(date -u -d "@$_t0" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "elapsed_seconds": $((_t1 - _t0)),
  "status": "$_status",
  "host": "$(hostname 2>/dev/null || echo unknown)",
  "jobs_run": $_ran,
  "jobs_failed": $_failed,
  "objects": $_objects,
  "bytes": $_bytes
}
EOF

	# A copy in the bucket means you can confirm the NAS is still backing up
	# without being able to reach the NAS -- which is exactly the situation a
	# backup exists for.
	if [ "$UPLOAD_RUN_REPORT" = true ]; then
		argv_reset
		argv_add copyto "$STATE_DIR/last-run.json" "$(remote_path '_nasbak/last-run.json')"
		argv_add --config /dev/null --s3-storage-class STANDARD --stats 0
		rclone_run >/dev/null 2>&1 || debug "run-report upload failed (non-fatal)"
	fi
}

log_rotate() {
	[ -d "$LOG_DIR" ] || return 0
	is_uint "$LOG_KEEP" || return 0
	[ "$LOG_KEEP" -lt 1 ] && return 0
	_lr_n=0
	# ls -t is newest-first; everything past LOG_KEEP goes.
	for _lr_f in $(ls -t "$LOG_DIR"/backup-*.log 2>/dev/null); do
		_lr_n=$((_lr_n + 1))
		[ "$_lr_n" -gt "$LOG_KEEP" ] && rm -f "$_lr_f"
	done
	return 0
}
