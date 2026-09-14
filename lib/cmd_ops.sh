#!/bin/sh
# lib/cmd_ops.sh -- status, restore, thaw, verify, prune.

# ------------------------------------------------------------------ status ---

cmd_status_usage() {
	cat <<'EOF'
Usage: nasbak status [--live]

  --live   Also LIST the bucket for current object counts and sizes. Costs a
           few LIST requests (fractions of a cent); everything else is read
           from local state.
EOF
}

cmd_status() {
	_live=false
	while [ $# -gt 0 ]; do
		case "$1" in
		--live) _live=true; shift ;;
		-h | --help) cmd_status_usage; return 0 ;;
		*) error "unknown option: $1"; return 2 ;;
		esac
	done

	config_load
	config_dirs
	jobs_snapshot_globals

	printf '\n%snasbak%s  %s -> s3://%s\n\n' "$C_BLD" "$C_OFF" \
		"$(hostname 2>/dev/null || echo NAS)" "$S3_BUCKET"

	_f="$STATE_DIR/last-run"
	if [ -f "$_f" ]; then
		_started=$(state_get "$_f" started)
		_finished=$(state_get "$_f" finished)
		_status=$(state_get "$_f" status)
		_objects=$(state_get "$_f" objects)
		_bytes=$(state_get "$_f" bytes)
		_failed=$(state_get "$_f" jobs_failed)

		_when=$(date -d "@$_started" '+%Y-%m-%d %H:%M' 2>/dev/null ||
			date -r "$_started" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$_started")
		_ago=$((($(date +%s) - _started) / 86400))

		if [ "$_status" = ok ]; then
			printf '  Last run      %s%s%s  (%s, %d day(s) ago)\n' "$C_GRN" OK "$C_OFF" "$_when" "$_ago"
		else
			printf '  Last run      %s%s%s  (%s, %s set(s) failed)\n' "$C_RED" FAILED "$C_OFF" "$_when" "$_failed"
		fi
		printf '  Took          %s\n' "$(human_duration "$((_finished - _started))")"
		printf '  Stored        %s in %s objects\n' "$(human_bytes "$_bytes")" "$_objects"
		status_cost_line "$_bytes" "$_objects"

		# A weekly backup that last ran a fortnight ago is a broken backup,
		# and nothing else on this screen would tell you.
		if [ "$_ago" -gt 9 ]; then
			printf '  %sStale:%s the last run was %d days ago. Check "nasbak cron status".\n' \
				"$C_RED" "$C_OFF" "$_ago"
		fi
	else
		printf '  Last run      %snever%s\n' "$C_YEL" "$C_OFF"
	fi

	printf '\n  Policy        %s for large files, %s under %s\n' \
		"$STORAGE_CLASS" "$SMALL_FILE_CLASS" "$SMALL_FILE_THRESHOLD"
	printf '  Undo window   %s days of superseded versions\n' "$VERSION_RETENTION_DAYS"
	printf '  Compare       %s\n' "$COMPARE_MODE"

	printf '\n  Schedule      '
	if cron_installed; then
		_sched=$( (sed -n 's/^\([0-9*].*\) root .*nasbak backup.*/\1/p' "$CRON_FILE" 2>/dev/null;
			have crontab && crontab -l 2>/dev/null | sed -n 's/^\([0-9*][^ ]* [^ ]* [^ ]* [^ ]* [^ ]*\) .*nasbak backup.*/\1/p') | head -n 1)
		printf '%s\n' "${_sched:-installed}"
	else
		printf '%snot scheduled%s\n' "$C_YEL" "$C_OFF"
	fi

	printf '\n  Backup sets\n'
	for _jf in $(jobs_list); do
		job_load "$_jf" || continue
		_mark='  '
		[ "$JOB_ENABLED" != true ] && _mark='- '
		printf '    %s%-12s %-38s %s\n' "$_mark" "$JOB_NAME" "$(ellipsise "$JOB_SOURCE" 38)" "$JOB_CLASS"
	done

	if [ "$_live" = true ]; then
		rclone_require
		rclone_env
		printf '\n  Live from S3\n'
		_tot_o=0 _tot_b=0
		for _jf in $(jobs_list); do
			job_load "$_jf" || continue
			_r=$(rclone_size "$(remote_path "$JOB_PREFIX")")
			_o=$(printf '%s' "$_r" | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 0}')
			_b=$(printf '%s' "$_r" | awk '{print ($2 ~ /^[0-9]+$/) ? $2 : 0}')
			printf '    %-12s %10s objects  %12s\n' "$JOB_NAME" "$_o" "$(human_bytes "$_b")"
			_tot_o=$((_tot_o + _o))
			_tot_b=$((_tot_b + _b))
		done
		printf '    %-12s %10s objects  %12s\n' TOTAL "$_tot_o" "$(human_bytes "$_tot_b")"
		status_cost_line "$_tot_b" "$_tot_o"
	fi
	printf '\n'
}

# A rough monthly figure from the stored bytes and object count. It assumes the
# whole set sits in STORAGE_CLASS, so it is an upper bound whenever the
# small-file split is doing its job.
status_cost_line() {
	_scl_bytes=$1
	_scl_objects=$2
	is_uint "$_scl_bytes" || return 0
	[ "$_scl_bytes" -le 0 ] && return 0
	awk -v b="$_scl_bytes" -v n="$_scl_objects" \
		-v rate="$(class_price_gb "$STORAGE_CLASS")" \
		-v minb="$(class_min_billable "$STORAGE_CLASS")" \
		-v ovc="$(class_overhead_class_bytes "$STORAGE_CLASS")" \
		-v ovs="$(class_overhead_standard_bytes "$STORAGE_CLASS")" \
		-v srate="$(class_price_gb STANDARD)" \
		-v cls="$STORAGE_CLASS" '
		BEGIN {
			GB = 1073741824
			# Per-object minimums and overheads need the object count, which
			# is why this is not just bytes * rate.
			lo = b
			hi = b
			if (ovc > 0) { lo += n * ovc; hi = lo }
			# Classes with a minimum billable size charge at least n * minb.
			# We only have totals here, not the distribution, so the truth is
			# somewhere between "no file is under the minimum" and "every one
			# is". Show the range rather than pick one and be quietly wrong.
			if (minb > 0 && n * minb > hi) hi = n * minb
			clo = lo * rate / GB
			chi = hi * rate / GB
			if (ovs > 0) { clo += n * ovs * srate / GB; chi += n * ovs * srate / GB }
			if (chi - clo > 0.01)
				printf "  Cost          ~$%.2f-$%.2f/month at %s list price (run \"nasbak estimate\" to narrow it)\n", clo, chi, cls
			else
				printf "  Cost          ~$%.2f/month at %s list price\n", chi, cls
		}'
}

# ----------------------------------------------------------------- restore ---

cmd_restore_usage() {
	cat <<'EOF'
Usage: nasbak restore --job NAME --to DIR [options]

  -j, --job NAME     Which backup set to restore from (required).
      --to DIR       Where to write the restored files (required).
      --path SUBPATH Restore only this subpath of the set.
      --at WHEN      Restore the bucket as it was at this time, e.g.
                     "2025-03-01" or "2025-03-01T14:00:00Z". Reads object
                     versions, so it also recovers files deleted since.
  -n, --dry-run      List what would be restored; download nothing.
      --yes          Do not prompt for confirmation.

Restoring is the expensive direction: egress is billed per GB, and archive
classes add a retrieval charge on top. Run with --dry-run first, and if the
data is in GLACIER or DEEP_ARCHIVE run "nasbak thaw" before this.
EOF
}

cmd_restore() {
	_job='' _to='' _sub='' _at='' _dry=false _yes=false
	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job) _job=$2; shift 2 ;;
		--to) _to=$2; shift 2 ;;
		--path) _sub=$2; shift 2 ;;
		--at) _at=$2; shift 2 ;;
		-n | --dry-run) _dry=true; shift ;;
		--yes) _yes=true; shift ;;
		-h | --help) cmd_restore_usage; return 0 ;;
		*) error "unknown option: $1"; cmd_restore_usage; return 2 ;;
		esac
	done

	config_load
	config_validate
	jobs_snapshot_globals
	rclone_require
	rclone_env

	[ -n "$_job" ] || die "--job is required"
	[ -n "$_to" ] || die "--to is required"
	job_load "$JOBS_DIR/$_job.job" || return 1

	_src=$(remote_path "$JOB_PREFIX")
	[ -n "$_sub" ] && _src="$_src/$(printf '%s' "$_sub" | sed 's:^/*::')"

	info "restore $_src -> $_to"
	[ -n "$_at" ] && info "reading the bucket as it was at: $_at"

	_r=$(rclone_size "$_src")
	_o=$(printf '%s' "$_r" | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 0}')
	_b=$(printf '%s' "$_r" | awk '{print ($2 ~ /^[0-9]+$/) ? $2 : 0}')
	info "$_o objects, $(human_bytes "$_b")"
	restore_cost_warning "$_b"

	if [ "$_dry" = false ] && [ "$_yes" = false ]; then
		printf 'Proceed with the download? [y/N] ' >&2
		read -r _ans
		case "$_ans" in
		y | Y | yes | YES) : ;;
		*) info "cancelled"; return 1 ;;
		esac
	fi

	mkdir -p "$_to" || die "cannot create $_to"
	NB_RUN_LOG="$LOG_DIR/restore-$(date '+%Y%m%d-%H%M%S').log"
	config_dirs

	argv_reset
	argv_add copy "$_src" "$_to"
	argv_add_common
	argv_add --progress
	# Restores must be byte-exact, so ignore COMPARE_MODE and verify hashes.
	argv_add --checksum
	[ -n "$_at" ] && argv_add --s3-version-at "$_at"
	[ "$_dry" = true ] && argv_add --dry-run --verbose

	if rclone_run; then
		ok "restore complete -> $_to"
		[ "$_dry" = false ] && info "verify it with: nasbak verify --job $_job --deep"
	else
		error "restore failed; see $NB_RUN_LOG"
		error "if these objects are in GLACIER or DEEP_ARCHIVE, thaw them first:"
		error "  nasbak thaw --job $_job"
		return 1
	fi
}

restore_cost_warning() {
	_rcw_b=$1
	awk -v b="$_rcw_b" -v eg="$PRICE_EGRESS_GB" \
		-v ret="$(class_price_retrieve_gb "$JOB_CLASS")" -v cls="$JOB_CLASS" '
		BEGIN {
			GB = 1073741824
			g = b / GB
			e = (g > 100) ? (g - 100) * eg : 0
			r = g * ret
			printf "estimated cost of this restore: $%.2f retrieval (%s) + $%.2f egress = $%.2f\n", r, cls, e, r + e
			if (g <= 100) printf "(the first 100 GB of egress each month is free, which covers this)\n"
		}' >&2
}

# -------------------------------------------------------------------- thaw ---

cmd_thaw_usage() {
	cat <<'EOF'
Usage: nasbak thaw --job NAME [options]

  -j, --job NAME      Backup set (required).
      --path SUBPATH  Thaw only this subpath.
      --priority P    Bulk | Standard | Expedited. Default Bulk.
      --days N        How long the thawed copy stays readable. Default 7.
      --status        Report on a thaw already in progress instead.

GLACIER and DEEP_ARCHIVE objects cannot be read until they are thawed.
GLACIER_IR, STANDARD and the IA classes need none of this -- restore directly.

  DEEP_ARCHIVE   Bulk 48 h ($0.0025/GB) | Standard 12 h ($0.02/GB)
  GLACIER        Bulk  5-12 h (free)    | Standard 3-5 h ($0.01/GB)

Bulk is much cheaper and, for a backup you hope never to read, the wait is
almost always worth it.
EOF
}

cmd_thaw() {
	_job='' _sub='' _prio=Bulk _days=7 _status=false
	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job) _job=$2; shift 2 ;;
		--path) _sub=$2; shift 2 ;;
		--priority) _prio=$2; shift 2 ;;
		--days) _days=$2; shift 2 ;;
		--status) _status=true; shift ;;
		-h | --help) cmd_thaw_usage; return 0 ;;
		*) error "unknown option: $1"; cmd_thaw_usage; return 2 ;;
		esac
	done

	config_load
	config_validate
	jobs_snapshot_globals
	rclone_require
	rclone_env
	[ -n "$_job" ] || die "--job is required"
	job_load "$JOBS_DIR/$_job.job" || return 1

	_src=$(remote_path "$JOB_PREFIX")
	[ -n "$_sub" ] && _src="$_src/$(printf '%s' "$_sub" | sed 's:^/*::')"

	if [ "$_status" = true ]; then
		argv_reset
		argv_add backend restore-status "$_src"
		argv_add --config /dev/null --stats 0
		rclone_run
		return $?
	fi

	case "$JOB_CLASS" in
	GLACIER | DEEP_ARCHIVE) : ;;
	*)
		info "[$_job] is stored in $JOB_CLASS, which is readable without thawing."
		info "Go straight to: nasbak restore --job $_job --to DIR"
		return 0
		;;
	esac

	info "thawing $_src ($JOB_CLASS, priority $_prio, readable for $_days day(s))"
	argv_reset
	argv_add backend restore "$_src"
	argv_add -o "priority=$_prio" -o "lifetime=$_days"
	argv_add --config /dev/null --stats 0
	if rclone_run; then
		ok "thaw requested"
		info "check progress with: nasbak thaw --job $_job --status"
		case "$_prio" in
		Bulk) info "bulk retrieval takes up to 48 h for DEEP_ARCHIVE, 5-12 h for GLACIER" ;;
		Standard) info "standard retrieval takes about 12 h for DEEP_ARCHIVE, 3-5 h for GLACIER" ;;
		esac
	else
		error "thaw request failed"
		return 1
	fi
}

# ------------------------------------------------------------------ verify ---

cmd_verify_usage() {
	cat <<'EOF'
Usage: nasbak verify [options]

  -j, --job NAME   Verify one backup set (default: all).
      --deep       Compare MD5 checksums instead of sizes. Re-reads every byte
                   off the NAS disks, but costs nothing extra in S3: the
                   checksums come from the ETag in the LIST response.
      --download   Re-download everything and compare byte for byte. This DOES
                   bill egress and archive retrieval. Rarely what you want.

Neither --deep nor the default mode transfers object data, so both are safe to
run against GLACIER_IR. Objects in GLACIER or DEEP_ARCHIVE must be thawed
before --download.
EOF
}

cmd_verify() {
	_only='' _mode=quick
	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job) _only="$_only $2"; shift 2 ;;
		--deep) _mode=deep; shift ;;
		--download) _mode=download; shift ;;
		-h | --help) cmd_verify_usage; return 0 ;;
		*) error "unknown option: $1"; cmd_verify_usage; return 2 ;;
		esac
	done

	config_load
	config_validate
	config_dirs
	jobs_snapshot_globals
	rclone_require
	rclone_env

	_rc=0
	for _jf in $(jobs_list); do
		job_load "$_jf" || continue
		if [ -n "$_only" ]; then
			case " $_only " in *" $JOB_NAME "*) : ;; *) continue ;; esac
		fi
		[ "$JOB_ENABLED" = true ] || continue
		job_preflight || { _rc=1; continue; }

		_dest=$(remote_path "$JOB_PREFIX")
		info "[$JOB_NAME] verifying ($_mode) $JOB_SOURCE against $_dest"

		argv_reset
		argv_add check "$JOB_SOURCE" "$_dest"
		# --one-way: extra objects in S3 are expected. The small-file pass may
		# briefly leave one behind, and a version kept for the undo window is
		# not an error.
		argv_add --one-way
		argv_add_common
		argv_add_filters "$JOB_EXCLUDES"
		case "$_mode" in
		quick) argv_add --size-only ;;
		deep) argv_add --checksum ;;
		download)
			argv_add --download
			warn "[$JOB_NAME] --download bills egress and retrieval for every object"
			;;
		esac

		if rclone_run; then
			ok "[$JOB_NAME] verified"
		else
			error "[$JOB_NAME] differences found (see the log above)"
			_rc=1
		fi
	done
	return "$_rc"
}

# ------------------------------------------------------------------- prune ---

cmd_prune_usage() {
	cat <<'EOF'
Usage: nasbak prune [--yes]

Aborts incomplete multipart uploads left behind by interrupted runs. Their
parts are billed as storage but are invisible in the console and in every
"total size" figure, so they are the classic silent S3 cost leak.

The bucket lifecycle rule already clears them after 7 days. This is for
reclaiming the space now.

Superseded object versions are NOT pruned from here: expiring them is the
lifecycle rule's job, and the NAS's IAM policy deliberately cannot delete
object versions, so that a compromised NAS cannot destroy your history.
EOF
}

cmd_prune() {
	_yes=false
	while [ $# -gt 0 ]; do
		case "$1" in
		--yes) _yes=true; shift ;;
		-h | --help) cmd_prune_usage; return 0 ;;
		*) error "unknown option: $1"; return 2 ;;
		esac
	done

	config_load
	config_validate
	config_dirs
	rclone_require
	rclone_env

	if [ "$_yes" = false ]; then
		printf 'Abort incomplete multipart uploads in s3://%s? [y/N] ' "$S3_BUCKET" >&2
		read -r _ans
		case "$_ans" in y | Y | yes | YES) : ;; *) info "cancelled"; return 1 ;; esac
	fi

	argv_reset
	argv_add cleanup "$(remote_path '')"
	argv_add --config /dev/null --stats 0 -v
	if rclone_run; then
		ok "incomplete multipart uploads cleared"
	else
		error "cleanup failed"
		return 1
	fi
}

# ---------------------------------------------------------------- versions ---

cmd_versions_usage() {
	cat <<'EOF'
Usage: nasbak versions --job NAME --path FILE

Lists every stored version of one file, newest first, with the timestamp each
became current. Recover one with:

  nasbak restore --job NAME --path FILE --to /tmp/recovered --at <timestamp>
EOF
}

cmd_versions() {
	_job='' _path=''
	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job) _job=$2; shift 2 ;;
		--path) _path=$2; shift 2 ;;
		-h | --help) cmd_versions_usage; return 0 ;;
		*) error "unknown option: $1"; return 2 ;;
		esac
	done

	config_load
	config_validate
	jobs_snapshot_globals
	rclone_require
	rclone_env
	[ -n "$_job" ] || die "--job is required"
	[ -n "$_path" ] || die "--path is required"
	job_load "$JOBS_DIR/$_job.job" || return 1

	_target="$(remote_path "$JOB_PREFIX")/$(printf '%s' "$_path" | sed 's:^/*::')"
	argv_reset
	argv_add lsl "$_target"
	argv_add --s3-versions --config /dev/null --stats 0
	rclone_run
}
