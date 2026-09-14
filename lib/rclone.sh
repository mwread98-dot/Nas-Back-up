#!/bin/sh
# lib/rclone.sh -- rclone installation and the flag sets we drive it with.

# POSIX sh has no arrays. Accumulate shell-quoted args in NB_ARGS and expand
# them with:  eval "set -- $NB_ARGS"
NB_ARGS=''

argv_reset() { NB_ARGS=''; }

argv_add() {
	for _av_a in "$@"; do
		NB_ARGS="$NB_ARGS '$(printf '%s' "$_av_a" | sed "s/'/'\\\\''/g")'"
	done
}

# ---------------------------------------------------------------- install ----

rclone_arch() {
	_m=$(uname -m 2>/dev/null || echo unknown)
	case "$_m" in
	x86_64 | amd64) printf 'linux-amd64' ;;
	i386 | i486 | i586 | i686) printf 'linux-386' ;;
	aarch64 | arm64) printf 'linux-arm64' ;;
	# The EX2 Ultra's Marvell Armada 385 is armv7l.
	armv7* | armv7l) printf 'linux-arm-v7' ;;
	armv6* | armv5* | arm) printf 'linux-arm' ;;
	*)
		error "unrecognised machine type '$_m'"
		return 1
		;;
	esac
}

_fetch() {
	# $1 url, $2 dest ('-' for stdout)
	if have curl; then
		if [ "$2" = '-' ]; then
			curl -fsSL --retry 3 --retry-delay 2 -m 600 "$1"
		else
			curl -fsSL --retry 3 --retry-delay 2 -m 600 -o "$2" "$1"
		fi
	elif have wget; then
		if [ "$2" = '-' ]; then
			wget -qO- "$1"
		else
			wget -qO "$2" "$1"
		fi
	else
		error "neither curl nor wget is available"
		return 1
	fi
}

_unzip_to() {
	# $1 zipfile, $2 destdir. My Cloud firmwares vary in what they ship.
	if have unzip; then
		unzip -oq "$1" -d "$2" && return 0
	fi
	if have busybox && busybox unzip -h >/dev/null 2>&1; then
		(cd "$2" && busybox unzip -oq "$1") && return 0
	fi
	if have python3; then
		python3 -m zipfile -e "$1" "$2" && return 0
	fi
	if have bsdtar; then
		bsdtar -xf "$1" -C "$2" && return 0
	fi
	error "no usable unzip. Install unzip, or download rclone by hand and set RCLONE_BIN."
	return 1
}

_sha256() {
	if have sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	elif have shasum; then
		shasum -a 256 "$1" | awk '{print $1}'
	elif have openssl; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	else
		printf ''
	fi
}

rclone_install() {
	_ri_dest=${1:-$RCLONE_BIN}
	_ri_arch=$(rclone_arch) || return 1
	_ri_tmp="${TMPDIR:-/tmp}/nasbak-rclone.$$"
	mkdir -p "$_ri_tmp" || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$_ri_tmp'" EXIT

	info "resolving latest rclone version"
	_ri_ver=$(_fetch 'https://downloads.rclone.org/version.txt' - | awk '{print $2}' | tr -d '\r')
	case "$_ri_ver" in
	v*) : ;;
	*)
		error "could not determine the current rclone version (got '$_ri_ver')"
		return 1
		;;
	esac

	_ri_zip="rclone-$_ri_ver-$_ri_arch.zip"
	_ri_base="https://downloads.rclone.org/$_ri_ver"
	info "downloading $_ri_zip"
	_fetch "$_ri_base/$_ri_zip" "$_ri_tmp/$_ri_zip" || {
		error "download failed: $_ri_base/$_ri_zip"
		return 1
	}

	# Verify against the published checksums rather than trusting the transfer.
	if _fetch "$_ri_base/SHA256SUMS" "$_ri_tmp/SHA256SUMS" 2>/dev/null; then
		_ri_want=$(awk -v f="$_ri_zip" '$2 == f || $2 == "*" f {print $1}' "$_ri_tmp/SHA256SUMS" | head -n 1)
		_ri_got=$(_sha256 "$_ri_tmp/$_ri_zip")
		if [ -n "$_ri_want" ] && [ -n "$_ri_got" ]; then
			[ "$_ri_want" = "$_ri_got" ] || {
				error "checksum mismatch for $_ri_zip"
				error "  expected $_ri_want"
				error "  got      $_ri_got"
				return 1
			}
			ok "checksum verified"
		else
			warn "could not verify the checksum (no sha256 tool or no matching entry)"
		fi
	else
		warn "could not fetch SHA256SUMS; skipping checksum verification"
	fi

	_unzip_to "$_ri_tmp/$_ri_zip" "$_ri_tmp" || return 1
	_ri_bin=$(find "$_ri_tmp" -type f -name rclone | head -n 1)
	[ -n "$_ri_bin" ] || {
		error "no rclone binary inside $_ri_zip"
		return 1
	}

	mkdir -p "$(dirname "$_ri_dest")" || return 1
	cp "$_ri_bin" "$_ri_dest.new" && chmod 755 "$_ri_dest.new" && mv -f "$_ri_dest.new" "$_ri_dest" || {
		error "could not install to $_ri_dest"
		return 1
	}
	rm -rf "$_ri_tmp"
	trap - EXIT
	ok "installed $("$_ri_dest" version 2>/dev/null | head -n 1) at $_ri_dest"
}

rclone_version_num() {
	# "v1.65.2" -> 16502, so versions compare as plain integers.
	"$RCLONE_BIN" version 2>/dev/null | awk '
		NR==1 {
			v=$2; sub(/^v/,"",v); split(v, p, ".")
			printf "%d", p[1]*10000 + p[2]*100 + p[3]
		}'
}

rclone_require() {
	[ -x "$RCLONE_BIN" ] || die "rclone not found at $RCLONE_BIN. Run 'nasbak install-rclone'."
	_rrq_v=$(rclone_version_num)
	if [ -n "$_rrq_v" ] && [ "$_rrq_v" -lt 15500 ]; then
		warn "rclone $("$RCLONE_BIN" version | head -n1) is old; 1.55+ is recommended."
	fi
}

# ------------------------------------------------------------------ flags ----

# Flags shared by every rclone invocation we make.
argv_add_common() {
	# Never read a stray rclone.conf: this remote is defined purely by the
	# environment (see rclone_env), which also keeps the secret out of argv.
	argv_add --config /dev/null
	argv_add --transfers "$TRANSFERS" --checkers "$CHECKERS"
	argv_add --buffer-size "$BUFFER_SIZE"
	argv_add --s3-chunk-size "$S3_CHUNK_SIZE"
	argv_add --s3-upload-concurrency "$S3_UPLOAD_CONCURRENCY"
	argv_add --retries 3 --retries-sleep 30s --low-level-retries 10
	argv_add --timeout 5m --contimeout 60s
	[ -n "$BWLIMIT" ] && argv_add --bwlimit "$BWLIMIT"
	[ -n "$TPSLIMIT" ] && argv_add --tpslimit "$TPSLIMIT"
	[ "${S3_NO_HEAD:-false}" = true ] && argv_add --s3-no-head
	if [ -n "$NB_RUN_LOG" ]; then
		argv_add --log-file "$NB_RUN_LOG" --log-level INFO
		argv_add --stats 5m --stats-one-line --stats-log-level NOTICE
	else
		argv_add --stats 0
	fi
	# shellcheck disable=SC2086
	[ -n "$RCLONE_EXTRA_ARGS" ] && argv_add $RCLONE_EXTRA_ARGS
	return 0
}

# How we decide whether a local file and an S3 object match.
argv_add_compare() {
	case "$COMPARE_MODE" in
	server-modtime)
		# LIST returns LastModified for free. rclone's stock modtime check
		# reads x-amz-meta-mtime instead, which costs one HEAD per object per
		# run -- the difference between a few cents and tens of dollars a
		# month once the object count gets real, especially on GLACIER_IR
		# where a HEAD is billed at the GET rate.
		#
		# --update is not optional here. The server modtime is the UPLOAD
		# time, which for an unchanged file is always later than the local
		# mtime. --update turns that into the rule we actually want -- upload
		# only when the local file is newer than the copy in S3 -- instead of
		# leaving rclone to resolve the mismatch by comparing hashes, which
		# would re-read every byte off the NAS every week.
		#
		# The trade-off: a file whose mtime moves BACKWARDS (restored from an
		# old archive over a newer copy) looks older than S3 and is skipped.
		# 'nasbak verify --deep' catches that; see docs/COSTS.md.
		argv_add --use-server-modtime --update
		;;
	size-only) argv_add --size-only ;;
	checksum) argv_add --checksum ;;
	modtime) : ;;
	esac
}

# --fast-list turns many LIST calls into few, at roughly 1 KB of RAM per
# object. On a 1 GB NAS that is a swap-death trap above a few hundred
# thousand objects, so it is opt-in by object count.
argv_add_fast_list() {
	_afl_objects=${1:-0}
	case "$FAST_LIST" in
	true) argv_add --fast-list ;;
	false) : ;;
	auto)
		if [ "$_afl_objects" -gt 0 ] && [ "$_afl_objects" -le "$FAST_LIST_MAX_OBJECTS" ]; then
			argv_add --fast-list
		fi
		;;
	esac
}

argv_add_filters() {
	_aff_job_excludes=$1
	[ -n "$_aff_job_excludes" ] && [ -f "$_aff_job_excludes" ] &&
		argv_add --filter-from "$_aff_job_excludes"
	_aff_global="$CONFIG_DIR/excludes.conf"
	[ -f "$_aff_global" ] && argv_add --filter-from "$_aff_global"
	return 0
}

# Run rclone, optionally de-prioritised so the NAS stays usable while the
# weekly sync grinds.
rclone_run() {
	eval "set -- $NB_ARGS"
	if [ "$USE_NICE" = true ] && have nice; then
		if have ionice; then
			nice -n "$NICE_LEVEL" ionice -c "$IONICE_CLASS" "$RCLONE_BIN" "$@"
		else
			nice -n "$NICE_LEVEL" "$RCLONE_BIN" "$@"
		fi
	else
		"$RCLONE_BIN" "$@"
	fi
}

# `rclone size --json` -> "count bytes". LIST requests only; no GET, no HEAD,
# so this is safe to call against archived storage classes.
rclone_size() {
	_rsz_path=$1
	argv_reset
	argv_add size --json "$_rsz_path"
	argv_add --config /dev/null
	argv_add --checkers "$CHECKERS" --stats 0
	shift
	for _rsz_extra in "$@"; do argv_add "$_rsz_extra"; done
	eval "set -- $NB_ARGS"
	"$RCLONE_BIN" "$@" 2>/dev/null |
		tr -d ' \n' |
		sed -n 's/.*"count":\([0-9-]*\).*"bytes":\([0-9-]*\).*/\1 \2/p'
}
