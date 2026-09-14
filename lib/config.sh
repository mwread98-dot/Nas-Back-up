#!/bin/sh
# lib/config.sh -- defaults, config loading, validation, rclone wiring.

# ------------------------------------------------------------------ defaults --

config_defaults() {
	# --- where things live -------------------------------------------------
	# Everything defaults under NASBAK_HOME, which lives on the DATA volume.
	# Never default to the rootfs: it is small on a My Cloud and a firmware
	# update wipes it.
	CONFIG_DIR="${CONFIG_DIR:-$NASBAK_HOME/config}"
	JOBS_DIR="${JOBS_DIR:-$CONFIG_DIR/jobs.d}"
	STATE_DIR="${STATE_DIR:-$NASBAK_HOME/state}"
	LOG_DIR="${LOG_DIR:-$NASBAK_HOME/logs}"
	LOCK_DIR="${LOCK_DIR:-$NASBAK_HOME/state/lock}"
	RCLONE_BIN="${RCLONE_BIN:-$NASBAK_HOME/bin/rclone}"
	LOG_KEEP="${LOG_KEEP:-26}"          # weekly runs -> ~6 months of logs
	LOCK_STALE_AFTER="${LOCK_STALE_AFTER:-86400}"

	# --- S3 target ---------------------------------------------------------
	S3_BUCKET="${S3_BUCKET:-}"
	S3_REGION="${S3_REGION:-us-east-1}"
	S3_PROVIDER="${S3_PROVIDER:-AWS}"   # AWS, Wasabi, Backblaze, Minio, Ceph...
	S3_ENDPOINT="${S3_ENDPOINT:-}"      # only for non-AWS S3-compatible stores
	S3_ROOT_PREFIX="${S3_ROOT_PREFIX:-}" # optional prefix shared by all jobs
	S3_ENV_AUTH="${S3_ENV_AUTH:-false}" # true = use AWS_PROFILE / instance role

	# Server-side encryption. AES256 (SSE-S3) is free; SSE-KMS bills per
	# request and per key, which a many-object backup feels immediately.
	SSE="${SSE:-AES256}"
	SSE_KMS_KEY_ID="${SSE_KMS_KEY_ID:-}"

	# --- storage-class policy ---------------------------------------------
	# See docs/COSTS.md for the arithmetic behind these defaults.
	STORAGE_CLASS="${STORAGE_CLASS:-GLACIER_IR}"
	SMALL_FILE_CLASS="${SMALL_FILE_CLASS:-STANDARD}"
	SMALL_FILE_THRESHOLD="${SMALL_FILE_THRESHOLD:-24k}"

	# --- comparison strategy ----------------------------------------------
	# server-modtime : LIST-only. No per-object HEAD, so no per-object request
	#                  charge. This is the default and it matters: on
	#                  GLACIER_IR a HEAD costs 25x a STANDARD one, and a HEAD
	#                  per object per week is the single easiest way to turn a
	#                  $2/month backup into a $30/month one.
	# size-only      : LIST-only, cheapest, misses same-size edits.
	# checksum       : compares local MD5 against the S3 ETag from the LIST
	#                  response. No extra S3 requests, but re-reads every byte
	#                  off the NAS disks. Use for `nasbak verify --deep`.
	# modtime        : rclone's stock behaviour. One HEAD per object. Correct,
	#                  and the expensive option. Opt in knowingly.
	COMPARE_MODE="${COMPARE_MODE:-server-modtime}"

	# --- safety ------------------------------------------------------------
	# A mirror propagates deletions. If a share fails to mount, an unguarded
	# sync happily empties the bucket. These are the brakes.
	MAX_DELETE_PCT="${MAX_DELETE_PCT:-5}"
	MAX_DELETE_ABS="${MAX_DELETE_ABS:-0}"   # 0 = derive from MAX_DELETE_PCT
	REQUIRE_CANARY="${REQUIRE_CANARY:-true}"
	CANARY_NAME="${CANARY_NAME:-.nasbak-canary}"
	MIN_SOURCE_FILES="${MIN_SOURCE_FILES:-1}"

	# --- version history ---------------------------------------------------
	# The bucket keeps noncurrent versions; lifecycle expires them. That gives
	# "one live copy + a bounded undo window" instead of the monthly full
	# duplicate the stock My Cloud app makes.
	VERSION_RETENTION_DAYS="${VERSION_RETENTION_DAYS:-90}"
	# Keep at least this many superseded versions per file even once they are
	# older than VERSION_RETENTION_DAYS. 0 removes the floor.
	KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
	# Keep old versions under a dated _versions/ prefix instead of relying on
	# bucket versioning. Costs a server-side COPY per changed file; only worth
	# it if you cannot enable versioning on the bucket.
	BACKUP_DIR_MODE="${BACKUP_DIR_MODE:-false}"

	# --- transfer tuning (sized for a 1 GB-RAM dual-core ARM NAS) ----------
	TRANSFERS="${TRANSFERS:-2}"
	CHECKERS="${CHECKERS:-8}"
	S3_CHUNK_SIZE="${S3_CHUNK_SIZE:-16M}"
	S3_UPLOAD_CONCURRENCY="${S3_UPLOAD_CONCURRENCY:-2}"
	# Skipping the post-upload HEAD saves one request per uploaded object but
	# removes rclone's integrity check. Not worth it for a backup.
	S3_NO_HEAD="${S3_NO_HEAD:-false}"
	BUFFER_SIZE="${BUFFER_SIZE:-4M}"
	BWLIMIT="${BWLIMIT:-}"
	TPSLIMIT="${TPSLIMIT:-}"
	FAST_LIST="${FAST_LIST:-auto}"      # auto|true|false
	FAST_LIST_MAX_OBJECTS="${FAST_LIST_MAX_OBJECTS:-200000}"
	RCLONE_EXTRA_ARGS="${RCLONE_EXTRA_ARGS:-}"

	# --- politeness --------------------------------------------------------
	USE_NICE="${USE_NICE:-true}"
	NICE_LEVEL="${NICE_LEVEL:-15}"
	IONICE_CLASS="${IONICE_CLASS:-3}"   # 3 = idle

	# --- reporting ---------------------------------------------------------
	HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
	NOTIFY_URL="${NOTIFY_URL:-}"
	NOTIFY_FORMAT="${NOTIFY_FORMAT:-text}"
	NOTIFY_ON="${NOTIFY_ON:-fail}"      # fail|always|never
	UPLOAD_RUN_REPORT="${UPLOAD_RUN_REPORT:-true}"

	# --- pricing (US East (N. Virginia) list prices, USD) ------------------
	# Only used by `nasbak estimate`. Override in nasbak.conf for your region.
	PRICE_GB_STANDARD="${PRICE_GB_STANDARD:-0.023}"
	PRICE_GB_STANDARD_IA="${PRICE_GB_STANDARD_IA:-0.0125}"
	PRICE_GB_ONEZONE_IA="${PRICE_GB_ONEZONE_IA:-0.01}"
	PRICE_GB_GLACIER_IR="${PRICE_GB_GLACIER_IR:-0.004}"
	PRICE_GB_GLACIER="${PRICE_GB_GLACIER:-0.0036}"
	PRICE_GB_DEEP_ARCHIVE="${PRICE_GB_DEEP_ARCHIVE:-0.00099}"
	PRICE_PUT_STANDARD="${PRICE_PUT_STANDARD:-0.005}"
	PRICE_PUT_STANDARD_IA="${PRICE_PUT_STANDARD_IA:-0.01}"
	PRICE_PUT_ONEZONE_IA="${PRICE_PUT_ONEZONE_IA:-0.01}"
	PRICE_PUT_GLACIER_IR="${PRICE_PUT_GLACIER_IR:-0.02}"
	PRICE_PUT_GLACIER="${PRICE_PUT_GLACIER:-0.03}"
	PRICE_PUT_DEEP_ARCHIVE="${PRICE_PUT_DEEP_ARCHIVE:-0.05}"
	PRICE_GET_STANDARD="${PRICE_GET_STANDARD:-0.0004}"
	PRICE_GET_STANDARD_IA="${PRICE_GET_STANDARD_IA:-0.001}"
	PRICE_GET_ONEZONE_IA="${PRICE_GET_ONEZONE_IA:-0.001}"
	PRICE_GET_GLACIER_IR="${PRICE_GET_GLACIER_IR:-0.01}"
	PRICE_GET_GLACIER="${PRICE_GET_GLACIER:-0.0004}"
	PRICE_GET_DEEP_ARCHIVE="${PRICE_GET_DEEP_ARCHIVE:-0.0004}"
	PRICE_LIST_1K="${PRICE_LIST_1K:-0.005}"
	PRICE_LIFECYCLE_TRANSITION_1K="${PRICE_LIFECYCLE_TRANSITION_1K:-0.01}"
	PRICE_EGRESS_GB="${PRICE_EGRESS_GB:-0.09}"
	PRICE_RETRIEVE_GB_GLACIER_IR="${PRICE_RETRIEVE_GB_GLACIER_IR:-0.03}"
	PRICE_RETRIEVE_GB_GLACIER="${PRICE_RETRIEVE_GB_GLACIER:-0.01}"
	PRICE_RETRIEVE_GB_DEEP_ARCHIVE="${PRICE_RETRIEVE_GB_DEEP_ARCHIVE:-0.02}"
	PRICE_IT_MONITORING_1K="${PRICE_IT_MONITORING_1K:-0.0025}"
}

# ------------------------------------------------------- storage-class facts --

# Minimum billable object size in bytes, per class. Storing a 4 KB file in
# GLACIER_IR bills you for 128 KB of it.
class_min_billable() {
	case "$(upper "$1")" in
	STANDARD_IA | ONEZONE_IA | GLACIER_IR) printf '131072' ;;
	*) printf '0' ;;
	esac
}

# Per-object metadata overhead in bytes, charged at the class rate.
# GLACIER and DEEP_ARCHIVE add 32 KB at class rate + 8 KB at STANDARD rate.
class_overhead_class_bytes() {
	case "$(upper "$1")" in
	GLACIER | DEEP_ARCHIVE) printf '32768' ;;
	*) printf '0' ;;
	esac
}

class_overhead_standard_bytes() {
	case "$(upper "$1")" in
	GLACIER | DEEP_ARCHIVE) printf '8192' ;;
	*) printf '0' ;;
	esac
}

# Minimum billable storage duration in days. Delete or overwrite sooner and
# you are still billed for the remainder.
class_min_days() {
	case "$(upper "$1")" in
	STANDARD_IA | ONEZONE_IA) printf '30' ;;
	GLACIER_IR | GLACIER) printf '90' ;;
	DEEP_ARCHIVE) printf '180' ;;
	*) printf '0' ;;
	esac
}

class_is_valid() {
	case "$(upper "$1")" in
	STANDARD | STANDARD_IA | ONEZONE_IA | INTELLIGENT_TIERING | GLACIER_IR | GLACIER | DEEP_ARCHIVE | REDUCED_REDUNDANCY)
		return 0
		;;
	*) return 1 ;;
	esac
}

class_price_gb() {
	case "$(upper "$1")" in
	STANDARD) printf '%s' "$PRICE_GB_STANDARD" ;;
	STANDARD_IA) printf '%s' "$PRICE_GB_STANDARD_IA" ;;
	ONEZONE_IA) printf '%s' "$PRICE_GB_ONEZONE_IA" ;;
	GLACIER_IR) printf '%s' "$PRICE_GB_GLACIER_IR" ;;
	GLACIER) printf '%s' "$PRICE_GB_GLACIER" ;;
	DEEP_ARCHIVE) printf '%s' "$PRICE_GB_DEEP_ARCHIVE" ;;
	INTELLIGENT_TIERING) printf '%s' "$PRICE_GB_STANDARD" ;;
	*) printf '%s' "$PRICE_GB_STANDARD" ;;
	esac
}

class_price_put_1k() {
	case "$(upper "$1")" in
	STANDARD) printf '%s' "$PRICE_PUT_STANDARD" ;;
	STANDARD_IA) printf '%s' "$PRICE_PUT_STANDARD_IA" ;;
	ONEZONE_IA) printf '%s' "$PRICE_PUT_ONEZONE_IA" ;;
	GLACIER_IR) printf '%s' "$PRICE_PUT_GLACIER_IR" ;;
	GLACIER) printf '%s' "$PRICE_PUT_GLACIER" ;;
	DEEP_ARCHIVE) printf '%s' "$PRICE_PUT_DEEP_ARCHIVE" ;;
	*) printf '%s' "$PRICE_PUT_STANDARD" ;;
	esac
}

class_price_get_1k() {
	case "$(upper "$1")" in
	STANDARD) printf '%s' "$PRICE_GET_STANDARD" ;;
	STANDARD_IA) printf '%s' "$PRICE_GET_STANDARD_IA" ;;
	ONEZONE_IA) printf '%s' "$PRICE_GET_ONEZONE_IA" ;;
	GLACIER_IR) printf '%s' "$PRICE_GET_GLACIER_IR" ;;
	GLACIER) printf '%s' "$PRICE_GET_GLACIER" ;;
	DEEP_ARCHIVE) printf '%s' "$PRICE_GET_DEEP_ARCHIVE" ;;
	*) printf '%s' "$PRICE_GET_STANDARD" ;;
	esac
}

class_price_retrieve_gb() {
	case "$(upper "$1")" in
	GLACIER_IR) printf '%s' "$PRICE_RETRIEVE_GB_GLACIER_IR" ;;
	GLACIER) printf '%s' "$PRICE_RETRIEVE_GB_GLACIER" ;;
	DEEP_ARCHIVE) printf '%s' "$PRICE_RETRIEVE_GB_DEEP_ARCHIVE" ;;
	STANDARD_IA | ONEZONE_IA) printf '0.01' ;;
	*) printf '0' ;;
	esac
}

# --------------------------------------------------------------- config load --

config_load() {
	config_defaults

	_cl_conf="$CONFIG_DIR/nasbak.conf"
	if [ -f "$_cl_conf" ]; then
		# shellcheck disable=SC1090
		. "$_cl_conf" || die "failed to read $_cl_conf"
		debug "loaded $_cl_conf"
	else
		debug "no config at $_cl_conf; using defaults"
	fi

	# Credentials live apart from config so the config can be readable,
	# diffable and version-controlled while the secret stays 0600.
	_cl_creds="$CONFIG_DIR/credentials"
	if [ -f "$_cl_creds" ]; then
		config_check_perms "$_cl_creds"
		# shellcheck disable=SC1090
		. "$_cl_creds" || die "failed to read $_cl_creds"
		debug "loaded credentials"
	fi

	# Re-run defaults so anything the config left unset still gets a value,
	# and so derived paths follow an overridden NASBAK_HOME.
	config_defaults
}

config_check_perms() {
	_ccp_f=$1
	_ccp_mode=$(stat -c %a "$_ccp_f" 2>/dev/null || stat -f %Lp "$_ccp_f" 2>/dev/null || echo '')
	[ -z "$_ccp_mode" ] && return 0
	case "$_ccp_mode" in
	*[04][04] | *00) return 0 ;;
	esac
	warn "$_ccp_f is mode $_ccp_mode; it holds your S3 secret key. Run: chmod 600 $_ccp_f"
}

config_validate() {
	[ -n "$S3_BUCKET" ] || die "S3_BUCKET is not set. Run 'nasbak init' first."
	class_is_valid "$STORAGE_CLASS" || die "invalid STORAGE_CLASS: $STORAGE_CLASS"
	class_is_valid "$SMALL_FILE_CLASS" || die "invalid SMALL_FILE_CLASS: $SMALL_FILE_CLASS"
	case "$COMPARE_MODE" in
	server-modtime | size-only | checksum | modtime) ;;
	*) die "invalid COMPARE_MODE: $COMPARE_MODE (server-modtime|size-only|checksum|modtime)" ;;
	esac
	if [ "$S3_ENV_AUTH" != true ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
		die "no AWS_ACCESS_KEY_ID. Put credentials in $CONFIG_DIR/credentials or set S3_ENV_AUTH=true."
	fi
	is_uint "$VERSION_RETENTION_DAYS" || die "VERSION_RETENTION_DAYS must be an integer"

	# The cost trap that bites people: noncurrent versions inherit the storage
	# class their object had when it was superseded. Expiring them before the
	# class minimum bills the untouched remainder as an early-deletion fee.
	# One line here; "nasbak check" explains it properly.
	_cv_min=$(class_min_days "$STORAGE_CLASS")
	if [ "$VERSION_RETENTION_DAYS" -gt 0 ] && [ "$VERSION_RETENTION_DAYS" -lt "$_cv_min" ]; then
		warn "VERSION_RETENTION_DAYS=$VERSION_RETENTION_DAYS is under the ${_cv_min}-day $STORAGE_CLASS minimum; expired versions still bill to ${_cv_min} days (nasbak check explains)"
	fi
}

config_dirs() {
	for _cd_d in "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR" "$JOBS_DIR"; do
		[ -d "$_cd_d" ] || mkdir -p "$_cd_d" || die "cannot create $_cd_d"
	done
}

# ------------------------------------------------------------ rclone wiring --

NB_REMOTE=nbs3

# Configure the remote purely through the environment. Two reasons: no
# rclone.conf to keep in sync, and the secret key never appears in argv where
# any user on the box could read it out of `ps`.
rclone_env() {
	RCLONE_CONFIG_NBS3_TYPE=s3
	RCLONE_CONFIG_NBS3_PROVIDER=$S3_PROVIDER
	RCLONE_CONFIG_NBS3_REGION=$S3_REGION
	# rclone would otherwise HeadBucket (and offer to create) on every run.
	# Skipping it removes a request and lets the IAM policy drop CreateBucket.
	RCLONE_CONFIG_NBS3_NO_CHECK_BUCKET=true
	export RCLONE_CONFIG_NBS3_TYPE RCLONE_CONFIG_NBS3_PROVIDER \
		RCLONE_CONFIG_NBS3_REGION RCLONE_CONFIG_NBS3_NO_CHECK_BUCKET

	if [ "$S3_ENV_AUTH" = true ]; then
		RCLONE_CONFIG_NBS3_ENV_AUTH=true
		export RCLONE_CONFIG_NBS3_ENV_AUTH
	else
		RCLONE_CONFIG_NBS3_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
		RCLONE_CONFIG_NBS3_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
		export RCLONE_CONFIG_NBS3_ACCESS_KEY_ID RCLONE_CONFIG_NBS3_SECRET_ACCESS_KEY
	fi

	if [ -n "$S3_ENDPOINT" ]; then
		RCLONE_CONFIG_NBS3_ENDPOINT=$S3_ENDPOINT
		export RCLONE_CONFIG_NBS3_ENDPOINT
	fi

	case "$SSE" in
	'' | none) : ;;
	aws:kms)
		RCLONE_CONFIG_NBS3_SERVER_SIDE_ENCRYPTION=aws:kms
		export RCLONE_CONFIG_NBS3_SERVER_SIDE_ENCRYPTION
		if [ -n "$SSE_KMS_KEY_ID" ]; then
			RCLONE_CONFIG_NBS3_SSE_KMS_KEY_ID=$SSE_KMS_KEY_ID
			export RCLONE_CONFIG_NBS3_SSE_KMS_KEY_ID
		fi
		;;
	*)
		RCLONE_CONFIG_NBS3_SERVER_SIDE_ENCRYPTION=$SSE
		export RCLONE_CONFIG_NBS3_SERVER_SIDE_ENCRYPTION
		;;
	esac
}

# Full remote path for a job prefix: nbs3:bucket[/root][/prefix]
remote_path() {
	_rp_p="$NB_REMOTE:$S3_BUCKET"
	[ -n "$S3_ROOT_PREFIX" ] && _rp_p="$_rp_p/$(printf '%s' "$S3_ROOT_PREFIX" | sed 's:^/*::; s:/*$::')"
	if [ -n "${1:-}" ]; then
		_rp_p="$_rp_p/$(printf '%s' "$1" | sed 's:^/*::; s:/*$::')"
	fi
	printf '%s' "$_rp_p"
}
