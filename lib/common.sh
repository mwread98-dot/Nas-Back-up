#!/bin/sh
# lib/common.sh -- shared helpers for nasbak.
# POSIX sh only: this has to run under busybox ash on the NAS.

# ---------------------------------------------------------------- colour/log --

NB_COLOUR=auto

_nb_use_colour() {
	case "$NB_COLOUR" in
	always) return 0 ;;
	never) return 1 ;;
	esac
	[ -t 2 ] || return 1
	[ -n "${TERM:-}" ] && [ "$TERM" != dumb ]
}

if _nb_use_colour; then
	C_RED=$(printf '\033[31m')
	C_YEL=$(printf '\033[33m')
	C_GRN=$(printf '\033[32m')
	C_DIM=$(printf '\033[2m')
	C_BLD=$(printf '\033[1m')
	C_OFF=$(printf '\033[0m')
else
	C_RED='' C_YEL='' C_GRN='' C_DIM='' C_BLD='' C_OFF=''
fi

# Log level: 0=debug 1=info 2=warn 3=error
NB_LOGLEVEL="${NB_LOGLEVEL:-1}"
NB_LOGFILE="${NB_LOGFILE:-}"

_nb_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_nb_emit() {
	# $1 level-name, $2 colour, $3.. message
	_nbe_lvl=$1
	_nbe_col=$2
	shift 2
	_nbe_line="$(_nb_ts) [$_nbe_lvl] $*"
	printf '%s%s%s\n' "$_nbe_col" "$_nbe_line" "$C_OFF" >&2
	[ -n "$NB_LOGFILE" ] && printf '%s\n' "$_nbe_line" >>"$NB_LOGFILE" 2>/dev/null
	return 0
}

debug() { [ "$NB_LOGLEVEL" -le 0 ] && _nb_emit DEBUG "$C_DIM" "$@"; return 0; }
info() { [ "$NB_LOGLEVEL" -le 1 ] && _nb_emit INFO "" "$@"; return 0; }
ok() { [ "$NB_LOGLEVEL" -le 1 ] && _nb_emit OK "$C_GRN" "$@"; return 0; }
warn() { [ "$NB_LOGLEVEL" -le 2 ] && _nb_emit WARN "$C_YEL" "$@"; return 0; }
error() { _nb_emit ERROR "$C_RED" "$@"; return 0; }

die() {
	error "$@"
	exit 1
}

# ------------------------------------------------------------------- helpers --

have() { command -v "$1" >/dev/null 2>&1; }

# Print $1 only if it is a non-empty string, else print $2.
default_to() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "$2"; }

# Portable uppercase (tr is present on busybox).
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Strictly-positive integer test.
is_uint() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Human-readable bytes. Integer maths only: no bc/printf %f on busybox.
human_bytes() {
	_hb_b=${1:-0}
	is_uint "$_hb_b" || {
		printf '%s' "$_hb_b"
		return
	}
	if [ "$_hb_b" -lt 1024 ]; then
		printf '%s B' "$_hb_b"
		return
	fi
	_hb_u=''
	for _hb_cand in KiB MiB GiB TiB PiB; do
		_hb_u=$_hb_cand
		_hb_prev=$_hb_b
		_hb_b=$((_hb_b / 1024))
		[ "$_hb_b" -lt 1024 ] && break
	done
	# one decimal place, computed from the pre-division value
	_hb_frac=$(((_hb_prev % 1024) * 10 / 1024))
	printf '%s.%s %s' "$_hb_b" "$_hb_frac" "$_hb_u"
}

# Parse "10G" / "512M" / "128k" / "4096" into bytes.
parse_size() {
	_psz_s=$1
	_psz_n=$(printf '%s' "$_psz_s" | sed 's/[^0-9].*$//')
	_psz_suf=$(printf '%s' "$_psz_s" | sed 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')
	is_uint "$_psz_n" || {
		error "not a size: $_psz_s"
		return 1
	}
	case "$_psz_suf" in
	'' | b) printf '%s' "$_psz_n" ;;
	k | kb | kib) printf '%s' "$((_psz_n * 1024))" ;;
	m | mb | mib) printf '%s' "$((_psz_n * 1024 * 1024))" ;;
	g | gb | gib) printf '%s' "$((_psz_n * 1024 * 1024 * 1024))" ;;
	t | tb | tib) printf '%s' "$((_psz_n * 1024 * 1024 * 1024 * 1024))" ;;
	*)
		error "unknown size suffix in '$_psz_s'"
		return 1
		;;
	esac
}

# Trim a string to fit a column, keeping the tail -- for a path, the last
# components are the informative ones.
ellipsise() {
	_ell_s=$1
	_ell_w=$2
	_ell_len=${#_ell_s}
	if [ "$_ell_len" -le "$_ell_w" ]; then
		printf '%s' "$_ell_s"
	else
		printf '...%s' "$(printf '%s' "$_ell_s" | cut -c "$((_ell_len - _ell_w + 4))-")"
	fi
}

# Seconds -> "1h 02m 03s"
human_duration() {
	_hd_t=${1:-0}
	_hd_h=$((_hd_t / 3600))
	_hd_m=$(((_hd_t % 3600) / 60))
	_hd_s=$((_hd_t % 60))
	if [ "$_hd_h" -gt 0 ]; then
		printf '%dh %02dm %02ds' "$_hd_h" "$_hd_m" "$_hd_s"
	elif [ "$_hd_m" -gt 0 ]; then
		printf '%dm %02ds' "$_hd_m" "$_hd_s"
	else
		printf '%ds' "$_hd_s"
	fi
}

# --------------------------------------------------------------------- locks --

# mkdir is atomic on every filesystem we care about, so it beats flock
# (absent from busybox on several My Cloud firmwares).
NB_LOCKDIR=''

lock_acquire() {
	_lka_dir=$1
	_lka_stale_after=${2:-86400}
	if mkdir "$_lka_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"$_lka_dir/pid"
		NB_LOCKDIR=$_lka_dir
		trap 'lock_release' EXIT INT TERM HUP
		return 0
	fi
	# Existing lock: is it alive?
	_lka_pid=$(cat "$_lka_dir/pid" 2>/dev/null || echo '')
	if [ -n "$_lka_pid" ] && kill -0 "$_lka_pid" 2>/dev/null; then
		error "another nasbak run is active (pid $_lka_pid, lock $_lka_dir)"
		return 1
	fi
	# No live owner. Only break the lock once it is convincingly old, so we
	# never stomp a run whose pid we simply cannot see.
	_lka_age=$(lock_age_seconds "$_lka_dir")
	if [ "$_lka_age" -ge "$_lka_stale_after" ]; then
		warn "breaking stale lock $_lka_dir (age ${_lka_age}s, owner pid ${_lka_pid:-unknown} gone)"
		rm -rf "$_lka_dir"
		lock_acquire "$_lka_dir" "$_lka_stale_after"
		return $?
	fi
	error "lock $_lka_dir held by dead pid ${_lka_pid:-unknown} but only ${_lka_age}s old; refusing to break it"
	error "remove it by hand once you are sure no backup is running: rm -rf $_lka_dir"
	return 1
}

lock_age_seconds() {
	_las_d=$1
	_las_now=$(date +%s)
	_las_then=$(file_mtime "$_las_d/pid")
	[ -z "$_las_then" ] && _las_then=$(file_mtime "$_las_d")
	[ -z "$_las_then" ] && {
		printf '0'
		return
	}
	printf '%s' "$((_las_now - _las_then))"
}

lock_release() {
	[ -n "$NB_LOCKDIR" ] || return 0
	rm -rf "$NB_LOCKDIR"
	NB_LOCKDIR=''
}

# mtime as a unix timestamp, across GNU stat / BSD stat / busybox / perl.
file_mtime() {
	[ -e "$1" ] || return 0
	stat -c %Y "$1" 2>/dev/null && return 0
	stat -f %m "$1" 2>/dev/null && return 0
	if have perl; then
		perl -e 'print ((stat($ARGV[0]))[9])' "$1" 2>/dev/null && return 0
	fi
	return 0
}

# ------------------------------------------------------------ notifications --

# Dead-man's-switch ping (healthchecks.io and compatible). $1 is '', 'start'
# or 'fail'. Never fatal: a missing ping must not fail a good backup.
hc_ping() {
	[ -n "${HEALTHCHECK_URL:-}" ] || return 0
	_hcp_suffix=$1
	_hcp_url=$HEALTHCHECK_URL
	[ -n "$_hcp_suffix" ] && _hcp_url="$HEALTHCHECK_URL/$_hcp_suffix"
	if have curl; then
		curl -fsS -m 20 --retry 3 -o /dev/null "$_hcp_url" 2>/dev/null ||
			debug "healthcheck ping failed: $_hcp_url"
	elif have wget; then
		wget -q -T 20 -O /dev/null "$_hcp_url" 2>/dev/null ||
			debug "healthcheck ping failed: $_hcp_url"
	fi
	return 0
}

# Generic webhook (ntfy, Slack, Discord, Gotify...). $1 title, $2 body.
notify() {
	_nty_title=$1
	_nty_body=$2
	[ -n "${NOTIFY_URL:-}" ] || return 0
	have curl || return 0
	case "${NOTIFY_FORMAT:-text}" in
	slack | discord)
		_nty_payload=$(json_obj text "$_nty_title

$_nty_body")
		curl -fsS -m 20 -o /dev/null -H 'Content-Type: application/json' \
			-d "$_nty_payload" "$NOTIFY_URL" 2>/dev/null || debug "notify failed"
		;;
	*)
		curl -fsS -m 20 -o /dev/null -H "Title: $_nty_title" \
			--data-binary "$_nty_body" "$NOTIFY_URL" 2>/dev/null || debug "notify failed"
		;;
	esac
	return 0
}

# Minimal JSON string escaper + single-key object builder.
json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' |
		awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

json_obj() { printf '{"%s":"%s"}' "$1" "$(json_escape "$2")"; }

# ------------------------------------------------------------------ atomics --

# Write stdin to $1 via a temp file in the same directory, so readers never
# see a half-written state file even if we are killed mid-write.
write_atomic() {
	_wa_dest=$1
	_wa_tmp="$_wa_dest.tmp.$$"
	cat >"$_wa_tmp" || {
		rm -f "$_wa_tmp"
		return 1
	}
	mv -f "$_wa_tmp" "$_wa_dest"
}

# Read KEY from a "KEY=value" state file.
state_get() {
	_stg_file=$1
	_stg_key=$2
	[ -f "$_stg_file" ] || return 0
	sed -n "s/^$_stg_key=//p" "$_stg_file" | tail -n 1
}
