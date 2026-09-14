#!/bin/sh
# lib/cmd_setup.sh -- first-run setup, job management, scheduling, health check.

# --------------------------------------------------------------------- init --

cmd_init_usage() {
	cat <<'EOF'
Usage: nasbak init [options]

  --bucket NAME       S3 bucket (required).
  --region REGION     Default us-east-1.
  --access-key ID     AWS access key id.
  --secret-key KEY    AWS secret access key. Prefer --secret-key-stdin.
  --secret-key-stdin  Read the secret key from stdin (keeps it out of shell
                      history and out of the process table).
  --class CLASS       Storage class for large files. Default GLACIER_IR.
  --small-class CLASS Storage class for small files. Default STANDARD.
  --endpoint URL      For non-AWS S3-compatible storage.
  --retention DAYS    Days a superseded file stays recoverable. Default 30.
  --force             Overwrite an existing config.
EOF
}

cmd_init() {
	_bucket='' _region='' _ak='' _sk='' _sk_stdin=false
	_class='' _small='' _endpoint='' _retention='' _force=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--bucket) _bucket=$2; shift 2 ;;
		--region) _region=$2; shift 2 ;;
		--access-key) _ak=$2; shift 2 ;;
		--secret-key) _sk=$2; shift 2 ;;
		--secret-key-stdin) _sk_stdin=true; shift ;;
		--class) _class=$(upper "$2"); shift 2 ;;
		--small-class) _small=$(upper "$2"); shift 2 ;;
		--endpoint) _endpoint=$2; shift 2 ;;
		--retention) _retention=$2; shift 2 ;;
		--force) _force=true; shift ;;
		-h | --help) cmd_init_usage; return 0 ;;
		*) opt_error "$1" "${2:-}"; cmd_init_usage; return 2 ;;
		esac
	done

	config_defaults
	config_dirs
	_conf="$CONFIG_DIR/nasbak.conf"
	_creds="$CONFIG_DIR/credentials"

	if [ -f "$_conf" ] && [ "$_force" != true ]; then
		die "$_conf already exists. Edit it, or pass --force to start over."
	fi

	[ -n "$_bucket" ] || die "--bucket is required"
	[ -n "$_class" ] && { class_is_valid "$_class" || die "invalid --class: $_class"; }
	[ -n "$_small" ] && { class_is_valid "$_small" || die "invalid --small-class: $_small"; }

	if [ "$_sk_stdin" = true ]; then
		IFS= read -r _sk || die "no secret key on stdin"
	fi

	# A silently-defaulted region is a trap: the bucket lives in exactly one
	# region, and getting it wrong surfaces much later as an opaque auth
	# failure rather than "wrong region".
	if [ -z "$_region" ]; then
		warn "no --region given, so this config says us-east-1."
		warn "If your bucket is anywhere else, re-run with:"
		warn "  nasbak init --force --bucket $_bucket --region YOUR-REGION --access-key ... --secret-key-stdin"
	fi
	_region=$(default_to "$_region" us-east-1)
	_class=$(default_to "$_class" GLACIER_IR)
	_small=$(default_to "$_small" STANDARD)
	_retention=$(default_to "$_retention" 90)

	umask 077
	{
		printf '# nasbak configuration -- generated %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '# Every setting here can be overridden per backup set in jobs.d/*.job.\n'
		printf '# Full reference: docs/CONFIG.md   Cost reasoning: docs/COSTS.md\n\n'
		printf '# --- destination ---------------------------------------------------\n'
		printf 'S3_BUCKET=%s\n' "$_bucket"
		printf 'S3_REGION=%s\n' "$_region"
		[ -n "$_endpoint" ] && printf 'S3_ENDPOINT=%s\nS3_PROVIDER=Other\n' "$_endpoint"
		printf 'SSE=AES256          # free. aws:kms bills per request.\n\n'
		printf '# --- storage class policy ------------------------------------------\n'
		printf '# Large files go to STORAGE_CLASS, anything under SMALL_FILE_THRESHOLD\n'
		printf '# goes to SMALL_FILE_CLASS. Archive tiers bill a 128 KiB minimum per\n'
		printf '# object, so tiny files really are cheaper in STANDARD.\n'
		printf '# Run "nasbak estimate" to get the right threshold for YOUR files.\n'
		printf 'STORAGE_CLASS=%s\n' "$_class"
		printf 'SMALL_FILE_CLASS=%s\n' "$_small"
		printf 'SMALL_FILE_THRESHOLD=24k\n\n'
		printf '# --- version history -----------------------------------------------\n'
		printf '# How long a superseded or deleted file stays recoverable. Only\n'
		printf '# changed files consume this; it is not a second full copy.\n'
		printf 'VERSION_RETENTION_DAYS=%s\n\n' "$_retention"
		printf '# --- comparison ----------------------------------------------------\n'
		printf '# server-modtime keeps the weekly run to LIST requests only.\n'
		printf '# See docs/COSTS.md before changing this to "modtime".\n'
		printf 'COMPARE_MODE=server-modtime\n\n'
		printf '# --- safety --------------------------------------------------------\n'
		printf 'MAX_DELETE_PCT=5    # abort if a run would delete more than this\n'
		printf 'REQUIRE_CANARY=true # refuse to sync a share that is not mounted\n\n'
		printf '# --- throughput (tuned for a 1 GB-RAM ARM NAS) ---------------------\n'
		printf 'TRANSFERS=2\n'
		printf 'CHECKERS=8\n'
		printf 'S3_CHUNK_SIZE=16M\n'
		printf 'S3_UPLOAD_CONCURRENCY=2\n'
		printf 'BUFFER_SIZE=4M\n'
		printf '#BWLIMIT=8M         # cap upload bandwidth, or "08:00,1M 23:00,off"\n\n'
		printf '# --- reporting -----------------------------------------------------\n'
		printf '#HEALTHCHECK_URL=https://hc-ping.com/YOUR-UUID\n'
		printf '#NOTIFY_URL=https://ntfy.sh/your-topic\n'
		printf 'NOTIFY_ON=fail      # fail|always|never\n'
	} >"$_conf"
	chmod 644 "$_conf"
	ok "wrote $_conf"

	if [ -n "$_ak" ] || [ -n "$_sk" ]; then
		{
			printf '# nasbak S3 credentials. Keep this file mode 600.\n'
			printf 'AWS_ACCESS_KEY_ID=%s\n' "$_ak"
			printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$_sk"
		} >"$_creds"
		chmod 600 "$_creds"
		ok "wrote $_creds (mode 600)"
	else
		warn "no credentials given. Create $_creds with:"
		warn "  AWS_ACCESS_KEY_ID=..."
		warn "  AWS_SECRET_ACCESS_KEY=..."
		warn "then: chmod 600 $_creds"
	fi

	setup_default_excludes

	cat <<EOF

Next:
  1. nasbak bootstrap --script > setup-s3.sh   # run it on a workstation
  2. nasbak add-job photos --source /shares/Photos
  3. nasbak estimate                           # what it will cost
  4. nasbak check                              # verify everything works
  5. nasbak backup --dry-run                   # see what the first run would do
  6. nasbak cron install                       # weekly, Sunday 02:00
EOF
}

setup_default_excludes() {
	_sde_f="$CONFIG_DIR/excludes.conf"
	[ -f "$_sde_f" ] && return 0
	cat >"$_sde_f" <<'EOF'
# rclone filter rules, applied to every backup set. "- pattern" excludes.
# Order matters: the first matching rule wins.
# Reference: https://rclone.org/filtering/

# --- WD My Cloud internals ------------------------------------------------
- .systemfile/**
- .wdmc/**
- .wdphotos/**
- .wdplugins/**
- .recycle_bin/**
- .@__thumb/**
- lost+found/**
- Nas_Prog/**
- TimeMachineBackup/**

# --- macOS ----------------------------------------------------------------
- .DS_Store
- ._*
- .AppleDouble/**
- .AppleDB/**
- .AppleDesktop/**
- .Spotlight-V100/**
- .TemporaryItems/**
- .fseventsd/**
- .Trashes/**
- .apdisk
- Network Trash Folder/**

# --- Windows --------------------------------------------------------------
- Thumbs.db
- ehthumbs.db
- desktop.ini
- $RECYCLE.BIN/**
- System Volume Information/**

# --- Linux ----------------------------------------------------------------
- .Trash-*/**
- .directory

# --- transient junk that is not worth archive-tier minimums ---------------
- *.tmp
- *.temp
- *.part
- *.crdownload
- *.!ut
- **/cache/**
- **/Cache/**
- **/.cache/**
- **/node_modules/**
- **/__pycache__/**

# Uncomment if your NAS holds VM images or disk images you do not need
# offsite. They are large and they change constantly, which is the worst
# combination for an archive storage class.
#- *.vmdk
#- *.vdi
#- *.iso
EOF
	ok "wrote $_sde_f"
}

# ----------------------------------------------------------------- add-job ---

cmd_addjob_usage() {
	cat <<'EOF'
Usage: nasbak add-job NAME --source PATH [options]

  --source PATH     Directory to back up (required).
  --prefix P        Destination prefix in the bucket. Default: NAME.
  --class CLASS     Storage class for large files in this set.
  --small-class C   Storage class for small files in this set.
  --threshold SIZE  Small/large boundary, e.g. 24k.
  --no-canary       Do not require the mount-guard file. Not recommended.
  --disabled        Create the set but do not run it yet.
  --force           Overwrite an existing set of this name.
EOF
}

cmd_add_job() {
	[ $# -ge 1 ] || { cmd_addjob_usage; return 2; }
	_name=$1
	shift
	case "$_name" in
	-* | '') error "the first argument must be a name"; cmd_addjob_usage; return 2 ;;
	*[!A-Za-z0-9_-]*) die "job names may only contain letters, digits, '-' and '_'" ;;
	esac

	_source='' _prefix='' _class='' _small='' _thresh='' _canary=true
	_enabled=true _force=false
	while [ $# -gt 0 ]; do
		case "$1" in
		--source) _source=$2; shift 2 ;;
		--prefix) _prefix=$2; shift 2 ;;
		--class) _class=$(upper "$2"); shift 2 ;;
		--small-class) _small=$(upper "$2"); shift 2 ;;
		--threshold) _thresh=$2; shift 2 ;;
		--no-canary) _canary=false; shift ;;
		--disabled) _enabled=false; shift ;;
		--force) _force=true; shift ;;
		-h | --help) cmd_addjob_usage; return 0 ;;
		*) opt_error "$1" "${2:-}"; cmd_addjob_usage; return 2 ;;
		esac
	done

	config_load
	config_dirs
	[ -n "$_source" ] || die "--source is required"
	[ -d "$_source" ] || die "not a directory: $_source"
	[ -n "$_class" ] && { class_is_valid "$_class" || die "invalid --class: $_class"; }
	[ -n "$_small" ] && { class_is_valid "$_small" || die "invalid --small-class: $_small"; }
	[ -n "$_thresh" ] && { parse_size "$_thresh" >/dev/null || die "invalid --threshold: $_thresh"; }

	# Strip any trailing slash: rclone treats "/path" and "/path/" the same,
	# but the canary check and the log lines read better without it.
	_source=$(printf '%s' "$_source" | sed 's:/*$::')
	[ -n "$_source" ] || _source=/

	_file="$JOBS_DIR/$_name.job"
	[ -f "$_file" ] && [ "$_force" != true ] &&
		die "$_file already exists. Edit it, or pass --force."

	{
		printf '# nasbak backup set "%s" -- created %s\n' "$_name" "$(date '+%Y-%m-%d')"
		printf '# Anything left unset is inherited from config/nasbak.conf.\n\n'
		printf 'SOURCE=%s\n' "$_source"
		printf 'ENABLED=%s\n' "$_enabled"
		[ -n "$_prefix" ] && printf 'DEST_PREFIX=%s\n' "$_prefix"
		[ -n "$_class" ] && printf 'STORAGE_CLASS=%s\n' "$_class"
		[ -n "$_small" ] && printf 'SMALL_FILE_CLASS=%s\n' "$_small"
		[ -n "$_thresh" ] && printf 'SMALL_FILE_THRESHOLD=%s\n' "$_thresh"
		[ "$_canary" = false ] && printf 'REQUIRE_CANARY=false\n'
		printf '\n# Extra rclone filter rules just for this set (optional):\n'
		printf '#EXCLUDES=%s/%s.filter\n' "$JOBS_DIR" "$_name"
	} >"$_file"
	ok "wrote $_file"

	if [ "$_canary" = true ]; then
		if job_write_canary "$_source" 2>/dev/null; then
			ok "wrote mount guard $_source/$CANARY_NAME"
		else
			warn "could not write $_source/$CANARY_NAME (read-only source?)"
			warn "either fix that, or add REQUIRE_CANARY=false to $_file"
		fi
	fi

	info "check it with: nasbak backup --dry-run --job $_name"
}

cmd_canary() {
	config_load
	jobs_snapshot_globals
	[ $# -ge 1 ] || die "usage: nasbak canary JOBNAME"
	for _n in "$@"; do
		_f="$JOBS_DIR/$_n.job"
		job_load "$_f" || return 1
		job_write_canary "$JOB_SOURCE" || die "could not write into $JOB_SOURCE"
		ok "[$JOB_NAME] wrote $JOB_SOURCE/$CANARY_NAME"
	done
}

cmd_jobs() {
	config_load
	jobs_snapshot_globals
	if [ "$(jobs_count)" -eq 0 ]; then
		info "no backup sets defined in $JOBS_DIR"
		return 0
	fi
	printf '%-14s %-8s %-34s %-14s %-12s\n' NAME ENABLED SOURCE CLASS PREFIX
	printf '%-14s %-8s %-34s %-14s %-12s\n' -------------- -------- \
		---------------------------------- -------------- ------------
	for _jf in $(jobs_list); do
		job_load "$_jf" || continue
		printf '%-14s %-8s %-34s %-14s %-12s\n' \
			"$JOB_NAME" "$JOB_ENABLED" "$(ellipsise "$JOB_SOURCE" 34)" "$JOB_CLASS" "$JOB_PREFIX"
	done
}

# -------------------------------------------------------------------- cron ---

CRON_FILE=/etc/cron.d/nasbak

cmd_cron_usage() {
	cat <<'EOF'
Usage: nasbak cron <install|remove|status|ensure> [options]

  install   Schedule the weekly run.
  ensure    Install only if it is missing. Safe to run repeatedly; this is
            what you call after a firmware update.
  remove    Unschedule.
  status    Show the current entry.

Options for install/ensure:
  --day N       0=Sunday .. 6=Saturday. Default 0.
  --hour N      0-23. Default 2.
  --minute N    0-59. Default 0.
  --schedule S  A raw five-field cron spec, instead of the above.
EOF
}

cmd_cron() {
	_action=${1:-status}
	[ $# -gt 0 ] && shift
	_day=0 _hour=2 _minute=0 _schedule=''
	while [ $# -gt 0 ]; do
		case "$1" in
		--day) _day=$2; shift 2 ;;
		--hour) _hour=$2; shift 2 ;;
		--minute) _minute=$2; shift 2 ;;
		--schedule) _schedule=$2; shift 2 ;;
		-h | --help) cmd_cron_usage; return 0 ;;
		*) opt_error "$1" "${2:-}"; cmd_cron_usage; return 2 ;;
		esac
	done

	config_load
	config_dirs
	[ -n "$_schedule" ] || _schedule="$_minute $_hour * * $_day"

	case "$_action" in
	install) cron_install "$_schedule" true ;;
	ensure) cron_install "$_schedule" false ;;
	remove) cron_remove ;;
	status) cron_status ;;
	*) error "unknown action: $_action"; cmd_cron_usage; return 2 ;;
	esac
}

cron_line() {
	printf '%s root %s backup >/dev/null 2>&1\n' "$1" "$NASBAK_HOME/bin/nasbak"
}

cron_install() {
	_cri_schedule=$1
	_cri_replace=$2

	if [ "$_cri_replace" != true ] && cron_installed; then
		debug "cron entry already present"
		return 0
	fi

	if [ -d /etc/cron.d ] && [ -w /etc/cron.d ]; then
		{
			printf '# nasbak weekly NAS -> S3 mirror. Managed by "nasbak cron".\n'
			printf 'SHELL=/bin/sh\n'
			printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
			cron_line "$_cri_schedule"
		} >"$CRON_FILE" || die "could not write $CRON_FILE"
		chmod 644 "$CRON_FILE"
		ok "installed $CRON_FILE: $_cri_schedule"
	elif have crontab; then
		_cri_tmp="${TMPDIR:-/tmp}/nasbak-cron.$$"
		crontab -l 2>/dev/null | grep -v 'bin/nasbak backup' >"$_cri_tmp" || :
		printf '%s %s backup >/dev/null 2>&1\n' "$_cri_schedule" "$NASBAK_HOME/bin/nasbak" >>"$_cri_tmp"
		crontab "$_cri_tmp" || { rm -f "$_cri_tmp"; die "crontab install failed"; }
		rm -f "$_cri_tmp"
		ok "installed a user crontab entry: $_cri_schedule"
	else
		die "no /etc/cron.d and no crontab command; schedule $NASBAK_HOME/bin/nasbak backup yourself"
	fi

	# Keep our own copy. My Cloud firmware updates replace /etc wholesale, so
	# "nasbak cron ensure" needs to know what to put back.
	printf '%s\n' "$_cri_schedule" >"$STATE_DIR/cron.schedule"
}

cron_installed() {
	[ -f "$CRON_FILE" ] && grep -q 'bin/nasbak' "$CRON_FILE" 2>/dev/null && return 0
	have crontab && crontab -l 2>/dev/null | grep -q 'bin/nasbak backup' && return 0
	return 1
}

cron_remove() {
	_crr_done=false
	if [ -f "$CRON_FILE" ]; then
		rm -f "$CRON_FILE" && ok "removed $CRON_FILE" && _crr_done=true
	fi
	if have crontab && crontab -l 2>/dev/null | grep -q 'bin/nasbak backup'; then
		_crr_tmp="${TMPDIR:-/tmp}/nasbak-cron.$$"
		crontab -l 2>/dev/null | grep -v 'bin/nasbak backup' >"$_crr_tmp"
		crontab "$_crr_tmp" && ok "removed the crontab entry" && _crr_done=true
		rm -f "$_crr_tmp"
	fi
	[ "$_crr_done" = true ] || info "nothing scheduled"
}

cron_status() {
	if cron_installed; then
		ok "scheduled"
		[ -f "$CRON_FILE" ] && sed -n '/nasbak/p' "$CRON_FILE" | sed 's/^/    /'
		have crontab && crontab -l 2>/dev/null | grep 'bin/nasbak backup' | sed 's/^/    /'
	else
		warn "not scheduled. Run: nasbak cron install"
		if [ -f "$STATE_DIR/cron.schedule" ]; then
			warn "a schedule was installed before ($(cat "$STATE_DIR/cron.schedule")) and has gone."
			warn "A firmware update will do that. Restore it with: nasbak cron ensure"
		fi
	fi
}


# Turn an rclone/AWS error dump into a plain-English cause. $1 is a file of
# captured stderr, $2 is "list" or "write" (which probe failed).
s3_explain() {
	_se_file=$1
	_se_stage=$2
	_se_txt=$(cat "$_se_file" 2>/dev/null)

	case "$_se_txt" in
	*InvalidAccessKeyId*)
		error "  cause: AWS does not recognise this access key id."
		error "  check: AWS_ACCESS_KEY_ID in $CONFIG_DIR/credentials against the"
		error "         AccessKeyId output of your CloudFormation stack."
		;;
	*SignatureDoesNotMatch*)
		error "  cause: the secret access key does not match the access key id."
		error "  check: re-enter it. Trailing spaces and a truncated paste both do this:"
		error "         nasbak init --force --bucket $S3_BUCKET --region $S3_REGION --access-key ... --secret-key-stdin"
		;;
	*RequestTimeTooSkewed* | *"clock"*)
		error "  cause: the NAS clock is more than 15 minutes out and AWS rejects the signature."
		error "  check: run 'date'. Fix with 'ntpd -q -p pool.ntp.org'."
		;;
	*PermanentRedirect* | *"301"* | *AuthorizationHeaderMalformed*)
		error "  cause: the bucket is not in $S3_REGION."
		error "  check: the Region output of your CloudFormation stack, then:"
		error "         nasbak init --force --bucket $S3_BUCKET --region THE-RIGHT-ONE --access-key ... --secret-key-stdin"
		;;
	*NoSuchBucket*)
		error "  cause: no bucket called '$S3_BUCKET' exists in this account."
		error "  check: the Bucket output of your CloudFormation stack. Names are exact."
		;;
	*403* | *Forbidden* | *AccessDenied*)
		if [ "$_se_stage" = list ]; then
			error "  cause: the key is valid, but its IAM policy does not cover this bucket."
			error "         The usual reason is a policy naming a DIFFERENT bucket -- which"
			error "         happens if you deployed the stack more than once, or renamed the"
			error "         bucket, and kept a key from the earlier attempt."
			error "  check: AWS Console -> IAM -> Users -> your nasbak user -> Permissions."
			error "         Open the nasbak-s3-access policy and read the Resource lines."
			error "         They must say arn:aws:s3:::$S3_BUCKET and arn:aws:s3:::$S3_BUCKET/*"
			error "         If they name another bucket, take the AccessKeyId and"
			error "         SecretAccessKey from the CloudFormation stack that owns THIS bucket."
		else
			error "  cause: the key can see the bucket but is denied writes."
			error "  check: the nasbak-s3-access policy grants s3:PutObject on"
			error "         arn:aws:s3:::$S3_BUCKET/* -- note the /* on the end. A policy with"
			error "         only the bare bucket ARN lists fine and writes nothing."
			error "         Also check for an explicit Deny, or a bucket policy that blocks it."
		fi
		;;
	*)
		error "  the raw error was:"
		sed 's/^/    /' "$_se_file" 2>/dev/null | tail -n 6 >&2
		return 0
		;;
	esac
	s3_show_raw "$_se_txt"
	return 0
}

# AWS puts the useful part -- "api error <Code>: <message>" -- at the END of the
# line, behind a RequestID and a HostID that are ~60 characters of noise each.
# A naive truncation drops exactly the token that names the fault, which makes a
# correct diagnosis look like a wrong guess. Lead with the code.
s3_show_raw() {
	_ssr_api=$(printf '%s' "$1" | tr '\n' ' ' |
		sed -n 's/.*\(api error [A-Za-z0-9]*: [^,]*\).*/\1/p' | head -n 1)
	if [ -n "$_ssr_api" ]; then
		error "  AWS said: $(printf '%s' "$_ssr_api" | cut -c1-150)"
	else
		error "  (raw error: $(printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200))"
	fi
	return 0
}

# A truncated or padded paste is the commonest cause of SignatureDoesNotMatch,
# and it costs nothing to catch offline: AWS access key ids are 20 characters
# and secret keys are exactly 40. Only checked for real AWS, since other
# S3-compatible providers use their own formats.
check_credential_shape() {
	[ "$S3_PROVIDER" = AWS ] || return 0
	_ccs_bad=0

	_ccs_id=${AWS_ACCESS_KEY_ID:-}
	_ccs_idlen=${#_ccs_id}
	case "$_ccs_id" in
	*[!A-Z0-9]*)
		error "credentials: AWS_ACCESS_KEY_ID has characters a key id never contains."
		error "  a stray quote, space or newline from the paste is the usual reason."
		_ccs_bad=1
		;;
	esac
	if [ "$_ccs_bad" -eq 0 ] && [ "$_ccs_idlen" -ne 20 ]; then
		error "credentials: AWS_ACCESS_KEY_ID is $_ccs_idlen characters; AWS key ids are 20."
		_ccs_bad=1
	fi

	_ccs_seclen=${#AWS_SECRET_ACCESS_KEY}
	if [ "$_ccs_seclen" -ne 40 ]; then
		error "credentials: AWS_SECRET_ACCESS_KEY is $_ccs_seclen characters; AWS secrets are exactly 40."
		if [ "$_ccs_seclen" -lt 40 ]; then
			error "  the paste was cut short. Copy it again from the stack's Outputs tab."
		else
			error "  something extra came with it -- a trailing space, quote or newline."
		fi
		_ccs_bad=1
	fi

	if [ "$_ccs_bad" -ne 0 ]; then
		error "  re-enter both with:"
		error "    nasbak init --force --bucket $S3_BUCKET --region $S3_REGION --access-key YOUR-KEY-ID --secret-key-stdin"
		return 1
	fi
	ok "credentials: key id and secret are both the right shape"
	return 0
}

# ------------------------------------------------------------------- check ---

cmd_check() {
	config_load
	config_dirs
	jobs_snapshot_globals
	_fail=0
	_warn=0

	info "--- tooling ---"
	if [ -x "$RCLONE_BIN" ]; then
		ok "rclone: $("$RCLONE_BIN" version 2>/dev/null | head -n 1) ($RCLONE_BIN)"
	else
		error "rclone missing at $RCLONE_BIN -- run 'nasbak install-rclone'"
		_fail=$((_fail + 1))
	fi
	for _t in curl date find awk sed; do
		have "$_t" || { error "missing required tool: $_t"; _fail=$((_fail + 1)); }
	done
	have ionice || { info "ionice absent; backups will run at nice $NICE_LEVEL only"; }

	info "--- configuration ---"
	if [ -z "$S3_BUCKET" ]; then
		error "S3_BUCKET is not set"
		_fail=$((_fail + 1))
	else
		ok "bucket: $S3_BUCKET (region $S3_REGION)"
	fi
	if class_is_valid "$STORAGE_CLASS"; then
		ok "class: $STORAGE_CLASS for large files, $SMALL_FILE_CLASS under $SMALL_FILE_THRESHOLD"
	else
		error "invalid STORAGE_CLASS: $STORAGE_CLASS"
		_fail=$((_fail + 1))
	fi
	_min=$(class_min_days "$STORAGE_CLASS")
	if [ "$VERSION_RETENTION_DAYS" -lt "$_min" ]; then
		warn "VERSION_RETENTION_DAYS=$VERSION_RETENTION_DAYS < ${_min}-day minimum for $STORAGE_CLASS"
		warn "  superseded versions are billed to ${_min} days regardless"
		_warn=$((_warn + 1))
	else
		ok "retention: $VERSION_RETENTION_DAYS days (>= the ${_min}-day $STORAGE_CLASS minimum)"
	fi
	if [ -f "$CONFIG_DIR/credentials" ]; then
		_mode=$(stat -c %a "$CONFIG_DIR/credentials" 2>/dev/null || echo '?')
		if [ "$_mode" = 600 ] || [ "$_mode" = 400 ]; then
			ok "credentials: present, mode $_mode"
		else
			warn "credentials: mode $_mode -- run: chmod 600 $CONFIG_DIR/credentials"
			_warn=$((_warn + 1))
		fi
		if ! check_credential_shape; then
			_fail=$((_fail + 1))
		fi
	elif [ "$S3_ENV_AUTH" = true ]; then
		ok "credentials: S3_ENV_AUTH=true (environment or instance role)"
	else
		error "no credentials at $CONFIG_DIR/credentials"
		_fail=$((_fail + 1))
	fi

	info "--- backup sets ---"
	if [ "$(jobs_count)" -eq 0 ]; then
		error "none defined -- run 'nasbak add-job'"
		_fail=$((_fail + 1))
	fi
	for _jf in $(jobs_list); do
		job_load "$_jf" || { _fail=$((_fail + 1)); continue; }
		if [ "$JOB_ENABLED" != true ]; then
			info "[$JOB_NAME] disabled"
			continue
		fi
		if job_validate >/dev/null && job_preflight >/dev/null 2>&1; then
			ok "[$JOB_NAME] $JOB_SOURCE -> $(remote_path "$JOB_PREFIX")"
		else
			job_validate || :
			job_preflight || :
			_fail=$((_fail + 1))
		fi
	done

	info "--- S3 reachability ---"
	if [ "$_fail" -eq 0 ] && [ -x "$RCLONE_BIN" ]; then
		rclone_env
		_err="$STATE_DIR/.probe.err"

		# Three probes in order of increasing privilege, because "403" on its
		# own cannot tell you whether the key is wrong, the bucket name is
		# wrong, or the key simply is not allowed to write. Knowing which of
		# these three steps failed narrows it to one cause.
		argv_reset
		argv_add lsd "$(remote_path '')"
		argv_add --config /dev/null --stats 0 --retries 1 --low-level-retries 1
		if rclone_run >/dev/null 2>"$_err"; then
			ok "the bucket is reachable and this key can list it"

			_probe="$STATE_DIR/.probe"
			printf 'nasbak connectivity probe %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >"$_probe"
			argv_reset
			argv_add copyto "$_probe" "$(remote_path '_nasbak/probe.txt')"
			argv_add --config /dev/null --stats 0 --s3-storage-class STANDARD
			argv_add --retries 1 --low-level-retries 1
			if rclone_run 2>"$_err"; then
				ok "wrote s3://$S3_BUCKET/_nasbak/probe.txt"
				argv_reset
				argv_add delete "$(remote_path '_nasbak/probe.txt')"
				argv_add --config /dev/null --stats 0
				if rclone_run >/dev/null 2>&1; then
					ok "delete works too"
				else
					warn "could not delete the probe object; mirroring needs s3:DeleteObject"
					_warn=$((_warn + 1))
				fi
			else
				error "this key can list the bucket but cannot write to it"
				s3_explain "$_err" write
				_fail=$((_fail + 1))
			fi
			rm -f "$_probe"
		else
			error "this key cannot reach the bucket at all"
			s3_explain "$_err" list
			_fail=$((_fail + 1))
		fi
		rm -f "$_err"
	else
		warn "skipped (fix the errors above first)"
	fi

	info "--- schedule ---"
	if cron_installed; then
		ok "weekly run is scheduled"
	else
		warn "not scheduled -- run 'nasbak cron install'"
		_warn=$((_warn + 1))
	fi
	if [ -n "$HEALTHCHECK_URL" ]; then
		ok "dead-man's switch configured"
	else
		warn "no HEALTHCHECK_URL. Without one, a backup that silently stops running"
		warn "  looks exactly like a backup that has nothing to do."
		_warn=$((_warn + 1))
	fi

	printf '\n'
	if [ "$_fail" -gt 0 ]; then
		error "$_fail problem(s), $_warn warning(s)"
		return 1
	fi
	ok "all checks passed ($_warn warning(s))"
	return 0
}

cmd_install_rclone() {
	config_load
	config_dirs
	rclone_install "$RCLONE_BIN"
}
