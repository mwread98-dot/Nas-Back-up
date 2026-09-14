#!/bin/sh
# lib/jobs.sh -- backup-set definitions (one .job file per set).

# Snapshot the global policy right after config_load so each job can inherit
# it cleanly and override only what it needs.
jobs_snapshot_globals() {
	G_STORAGE_CLASS=$STORAGE_CLASS
	G_SMALL_FILE_CLASS=$SMALL_FILE_CLASS
	G_SMALL_FILE_THRESHOLD=$SMALL_FILE_THRESHOLD
	G_MAX_DELETE_PCT=$MAX_DELETE_PCT
	G_MAX_DELETE_ABS=$MAX_DELETE_ABS
	G_REQUIRE_CANARY=$REQUIRE_CANARY
	G_MIN_SOURCE_FILES=$MIN_SOURCE_FILES
	G_BWLIMIT=$BWLIMIT
}

jobs_list() {
	[ -d "$JOBS_DIR" ] || return 0
	for _jls_f in "$JOBS_DIR"/*.job; do
		[ -f "$_jls_f" ] || continue
		printf '%s\n' "$_jls_f"
	done
}

jobs_count() { jobs_list | wc -l | tr -d ' '; }

# Load one .job file into JOB_* variables, inheriting unset knobs from the
# global policy.
job_load() {
	_jld_file=$1
	[ -f "$_jld_file" ] || {
		error "no such job file: $_jld_file"
		return 1
	}

	ENABLED=true
	SOURCE=''
	DEST_PREFIX=''
	EXCLUDES=''
	DESCRIPTION=''
	STORAGE_CLASS=$G_STORAGE_CLASS
	SMALL_FILE_CLASS=$G_SMALL_FILE_CLASS
	SMALL_FILE_THRESHOLD=$G_SMALL_FILE_THRESHOLD
	MAX_DELETE_PCT=$G_MAX_DELETE_PCT
	MAX_DELETE_ABS=$G_MAX_DELETE_ABS
	REQUIRE_CANARY=$G_REQUIRE_CANARY
	MIN_SOURCE_FILES=$G_MIN_SOURCE_FILES
	BWLIMIT=$G_BWLIMIT

	# shellcheck disable=SC1090
	. "$_jld_file" || {
		error "failed to read $_jld_file"
		return 1
	}

	JOB_FILE=$_jld_file
	JOB_NAME=$(basename "$_jld_file" .job)
	JOB_SOURCE=$SOURCE
	JOB_DESC=$DESCRIPTION
	JOB_ENABLED=$ENABLED
	JOB_PREFIX=$(default_to "$DEST_PREFIX" "$JOB_NAME")
	JOB_CLASS=$(upper "$STORAGE_CLASS")
	JOB_SMALL_CLASS=$(upper "$SMALL_FILE_CLASS")
	JOB_THRESHOLD=$SMALL_FILE_THRESHOLD
	JOB_EXCLUDES=$EXCLUDES
	JOB_MAX_DELETE_PCT=$MAX_DELETE_PCT
	JOB_MAX_DELETE_ABS=$MAX_DELETE_ABS
	JOB_REQUIRE_CANARY=$REQUIRE_CANARY
	JOB_MIN_SOURCE_FILES=$MIN_SOURCE_FILES
	JOB_BWLIMIT=$BWLIMIT

	# Restore the globals the job file just shadowed, so the next job (and
	# anything reading global policy) is not contaminated by this one.
	STORAGE_CLASS=$G_STORAGE_CLASS
	SMALL_FILE_CLASS=$G_SMALL_FILE_CLASS
	SMALL_FILE_THRESHOLD=$G_SMALL_FILE_THRESHOLD
	MAX_DELETE_PCT=$G_MAX_DELETE_PCT
	MAX_DELETE_ABS=$G_MAX_DELETE_ABS
	REQUIRE_CANARY=$G_REQUIRE_CANARY
	MIN_SOURCE_FILES=$G_MIN_SOURCE_FILES
	BWLIMIT=$G_BWLIMIT
}

job_validate() {
	[ -n "$JOB_SOURCE" ] || {
		error "[$JOB_NAME] SOURCE is not set in $JOB_FILE"
		return 1
	}
	class_is_valid "$JOB_CLASS" || {
		error "[$JOB_NAME] invalid STORAGE_CLASS: $JOB_CLASS"
		return 1
	}
	class_is_valid "$JOB_SMALL_CLASS" || {
		error "[$JOB_NAME] invalid SMALL_FILE_CLASS: $JOB_SMALL_CLASS"
		return 1
	}
	parse_size "$JOB_THRESHOLD" >/dev/null || {
		error "[$JOB_NAME] invalid SMALL_FILE_THRESHOLD: $JOB_THRESHOLD"
		return 1
	}
	return 0
}

# Guard rails, checked before anything is allowed to delete from S3.
#
# The failure this exists for: a share does not remount after a reboot, the
# mount point is left as an empty directory, `rclone sync` faithfully mirrors
# "empty" to S3, and the backup is gone. A canary file inside the share is
# only readable when the share is actually mounted.
job_preflight() {
	if [ ! -d "$JOB_SOURCE" ]; then
		error "[$JOB_NAME] source does not exist: $JOB_SOURCE"
		return 1
	fi

	if [ "$JOB_REQUIRE_CANARY" = true ]; then
		if [ ! -f "$JOB_SOURCE/$CANARY_NAME" ]; then
			error "[$JOB_NAME] canary file missing: $JOB_SOURCE/$CANARY_NAME"
			error "[$JOB_NAME] the share is probably not mounted. Refusing to sync."
			error "[$JOB_NAME] if the source really is this path, run: nasbak canary $JOB_NAME"
			return 1
		fi
	fi

	_jpf_n=$(job_count_entries "$JOB_SOURCE" "$JOB_MIN_SOURCE_FILES")
	if [ "$_jpf_n" -lt "$JOB_MIN_SOURCE_FILES" ]; then
		error "[$JOB_NAME] source holds $_jpf_n entries, below MIN_SOURCE_FILES=$JOB_MIN_SOURCE_FILES"
		error "[$JOB_NAME] refusing to mirror a source that looks empty."
		return 1
	fi
	return 0
}

# Count up to $2 entries and stop: never walk a multi-terabyte share just to
# answer "is there anything here".
job_count_entries() {
	_jce_dir=$1
	_jce_limit=${2:-1}
	[ "$_jce_limit" -lt 1 ] && _jce_limit=1
	find "$_jce_dir" -mindepth 1 -maxdepth 3 2>/dev/null | head -n "$_jce_limit" | wc -l | tr -d ' '
}

job_write_canary() {
	_jwc_dir=$1
	cat >"$_jwc_dir/$CANARY_NAME" <<CANEOF
This file tells nasbak that "$_jwc_dir" is really mounted.

If it is missing, nasbak refuses to sync -- because an unmounted share looks
like an empty directory, and mirroring an empty directory to S3 deletes the
backup. Do not remove it.

Created $(date '+%Y-%m-%d %H:%M:%S') by nasbak.
CANEOF
}
