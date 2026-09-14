#!/bin/sh
# lib/cmd_estimate.sh -- what this backup will actually cost, before you run it.
#
# Storage class pricing is not linear in bytes. Every archive class bills a
# minimum object size and a minimum storage duration, so a share full of 4 KB
# files can cost more in DEEP_ARCHIVE than in STANDARD. This walks the real
# file-size distribution and does the arithmetic.

cmd_estimate_usage() {
	cat <<'EOF'
Usage: nasbak estimate [options]

  -j, --job NAME      Estimate one backup set (default: all of them).
  -s, --source PATH   Estimate an arbitrary directory instead.
      --churn PCT     Percent of bytes assumed to change each run, for the
                      recurring-request estimate. Default 2.
      --restores N    Full restores per year to amortise. Default 0.
      --no-histogram  Skip the size-distribution table.

Prices come from PRICE_* in nasbak.conf (US East (N. Virginia) list prices by
default). Set them for your own region before trusting the totals.
EOF
}

cmd_estimate() {
	_only='' _source='' _churn=2 _restores=0 _hist=true
	while [ $# -gt 0 ]; do
		case "$1" in
		-j | --job) _only="$_only $2"; shift 2 ;;
		-s | --source) _source=$2; shift 2 ;;
		--churn) _churn=$2; shift 2 ;;
		--restores) _restores=$2; shift 2 ;;
		--no-histogram) _hist=false; shift ;;
		-h | --help) cmd_estimate_usage; return 0 ;;
		*) opt_error "$1" "${2:-}"; cmd_estimate_usage; return 2 ;;
		esac
	done

	config_load
	config_dirs
	jobs_snapshot_globals
	rclone_require

	_sizes="$STATE_DIR/.estimate-sizes.$$"
	: >"$_sizes"
	# shellcheck disable=SC2064
	trap "rm -f '$_sizes'" EXIT INT TERM

	if [ -n "$_source" ]; then
		info "scanning $_source"
		estimate_collect "$_source" '' >>"$_sizes"
	else
		[ "$(jobs_count)" -eq 0 ] && die "no backup sets defined in $JOBS_DIR"
		for _jf in $(jobs_list); do
			job_load "$_jf" || continue
			if [ -n "$_only" ]; then
				case " $_only " in *" $JOB_NAME "*) : ;; *) continue ;; esac
			fi
			[ -d "$JOB_SOURCE" ] || {
				warn "[$JOB_NAME] source missing: $JOB_SOURCE"
				continue
			}
			info "scanning [$JOB_NAME] $JOB_SOURCE"
			estimate_collect "$JOB_SOURCE" "$JOB_EXCLUDES" >>"$_sizes"
		done
	fi

	[ -s "$_sizes" ] || die "no files found to estimate"
	estimate_report "$_sizes" "$_churn" "$_restores" "$_hist"
	rm -f "$_sizes"
	trap - EXIT INT TERM
}

# rclone lsl is already on the box and honours the same filters the backup
# will, which busybox find (no -printf) does not.
estimate_collect() {
	_ec_path=$1
	_ec_job_excludes=$2
	argv_reset
	argv_add lsl "$_ec_path"
	argv_add --config /dev/null --stats 0 --checkers "$CHECKERS"
	argv_add_filters "$_ec_job_excludes"
	eval "set -- $NB_ARGS"
	"$RCLONE_BIN" "$@" 2>/dev/null | awk '{print $1+0}'
}

estimate_report() {
	_sizes=$1 _churn=$2 _restores=$3 _hist=$4

	awk \
		-v p_std="$(class_price_gb STANDARD)" \
		-v p_sia="$(class_price_gb STANDARD_IA)" \
		-v p_gir="$(class_price_gb GLACIER_IR)" \
		-v p_gla="$(class_price_gb GLACIER)" \
		-v p_dar="$(class_price_gb DEEP_ARCHIVE)" \
		-v put_std="$(class_price_put_1k STANDARD)" \
		-v put_sia="$(class_price_put_1k STANDARD_IA)" \
		-v put_gir="$(class_price_put_1k GLACIER_IR)" \
		-v put_gla="$(class_price_put_1k GLACIER)" \
		-v put_dar="$(class_price_put_1k DEEP_ARCHIVE)" \
		-v get_std="$(class_price_get_1k STANDARD)" \
		-v get_gir="$(class_price_get_1k GLACIER_IR)" \
		-v get_dar="$(class_price_get_1k DEEP_ARCHIVE)" \
		-v ret_gir="$(class_price_retrieve_gb GLACIER_IR)" \
		-v ret_gla="$(class_price_retrieve_gb GLACIER)" \
		-v ret_dar="$(class_price_retrieve_gb DEEP_ARCHIVE)" \
		-v p_list="$PRICE_LIST_1K" \
		-v p_egress="$PRICE_EGRESS_GB" \
		-v churn="$_churn" \
		-v restores="$_restores" \
		-v show_hist="$_hist" \
		-v cur_class="$STORAGE_CLASS" \
		-v cur_small="$SMALL_FILE_CLASS" \
		-v cur_mode="$COMPARE_MODE" \
		'
	BEGIN {
		GB = 1073741824          # AWS bills S3 storage per 2^30 bytes
		split("STANDARD STANDARD_IA GLACIER_IR GLACIER DEEP_ARCHIVE", CL, " ")
		NC = 5
		rate["STANDARD"]=p_std; rate["STANDARD_IA"]=p_sia
		rate["GLACIER_IR"]=p_gir; rate["GLACIER"]=p_gla; rate["DEEP_ARCHIVE"]=p_dar
		put["STANDARD"]=put_std; put["STANDARD_IA"]=put_sia
		put["GLACIER_IR"]=put_gir; put["GLACIER"]=put_gla; put["DEEP_ARCHIVE"]=put_dar
		getp["STANDARD"]=get_std; getp["STANDARD_IA"]=0.001
		getp["GLACIER_IR"]=get_gir; getp["GLACIER"]=get_dar; getp["DEEP_ARCHIVE"]=get_dar
		retr["STANDARD"]=0; retr["STANDARD_IA"]=0.01
		retr["GLACIER_IR"]=ret_gir; retr["GLACIER"]=ret_gla; retr["DEEP_ARCHIVE"]=ret_dar
		# minimum billable object size
		minb["STANDARD_IA"]=131072; minb["GLACIER_IR"]=131072
		# per-object overhead: 32 KiB at class rate + 8 KiB at STANDARD rate
		ovc["GLACIER"]=32768; ovs["GLACIER"]=8192
		ovc["DEEP_ARCHIVE"]=32768; ovs["DEEP_ARCHIVE"]=8192
		mind["STANDARD_IA"]=30; mind["GLACIER_IR"]=90
		mind["GLACIER"]=90; mind["DEEP_ARCHIVE"]=180

		nbuck = 9
		bedge[1]=1024; blab[1]="< 1 KiB"
		bedge[2]=8192; blab[2]="1 - 8 KiB"
		bedge[3]=24576; blab[3]="8 - 24 KiB"
		bedge[4]=131072; blab[4]="24 - 128 KiB"
		bedge[5]=1048576; blab[5]="128 KiB - 1 MiB"
		bedge[6]=16777216; blab[6]="1 - 16 MiB"
		bedge[7]=268435456; blab[7]="16 - 256 MiB"
		bedge[8]=1073741824; blab[8]="256 MiB - 1 GiB"
		bedge[9]=-1; blab[9]="> 1 GiB"
	}

	function cost_of(sz, c,   b) {
		if (minb[c] > 0) {
			b = (sz > minb[c]) ? sz : minb[c]
			return b * rate[c] / GB
		}
		if (ovc[c] > 0)
			return ((sz + ovc[c]) * rate[c] + ovs[c] * rate["STANDARD"]) / GB
		return sz * rate[c] / GB
	}

	{
		sz = $1 + 0
		n++
		bytes += sz
		if (sz == 0) zero++
		if (sz < 131072) { small++; smallbytes += sz }

		for (i = 1; i <= nbuck; i++) {
			if (bedge[i] < 0 || sz < bedge[i]) { bcount[i]++; bbytes[i] += sz; break }
		}

		for (c = 1; c <= NC; c++) {
			cls = CL[c]
			cst = cost_of(sz, cls)
			total[cls] += cst
			# billable bytes, for showing the minimum-size penalty
			if (minb[cls] > 0) billb[cls] += (sz > minb[cls] ? sz : minb[cls])
			else if (ovc[cls] > 0) billb[cls] += sz + ovc[cls] + ovs[cls]
			else billb[cls] += sz
		}

		# Optimal per-file assignment between STANDARD and each archive class.
		# Both cost curves are monotonic in size and cross once, so the
		# cheapest per-file choice IS a threshold rule -- we just record where
		# the crossover actually falls for this data.
		cs = cost_of(sz, "STANDARD")
		for (c = 2; c <= NC; c++) {
			cls = CL[c]
			ca = cost_of(sz, cls)
			if (cs <= ca) {
				split_total[cls] += cs
				split_small_n[cls]++
				if (sz > split_edge[cls]) split_edge[cls] = sz
			} else {
				split_total[cls] += ca
				split_big_n[cls]++
			}
		}
	}

	function money(v) {
		if (v >= 100) return sprintf("$%.0f", v)
		if (v >= 10)  return sprintf("$%.2f", v)
		if (v >= 0.01) return sprintf("$%.3f", v)
		return sprintf("$%.4f", v)
	}
	function hb(b,   u, i, v) {
		split("B KiB MiB GiB TiB PiB", u, " ")
		v = b; i = 1
		while (v >= 1024 && i < 6) { v /= 1024; i++ }
		return sprintf("%.1f %s", v, u[i])
	}
	function bar(frac,   s, k, w) {
		w = int(frac * 28 + 0.5); s = ""
		for (k = 0; k < w; k++) s = s "#"
		return s
	}

	END {
		if (n == 0) { print "no files scanned"; exit 1 }
		printf "\n"
		printf "================================================================\n"
		printf " Backup set profile\n"
		printf "================================================================\n"
		printf "  Files                 %12d\n", n
		printf "  Total size            %12s\n", hb(bytes)
		printf "  Mean file size        %12s\n", hb(bytes / n)
		printf "  Files under 128 KiB   %12d  (%.1f%% of files, %.2f%% of bytes)\n", \
			small, 100 * small / n, (bytes > 0 ? 100 * smallbytes / bytes : 0)
		if (zero > 0) printf "  Zero-byte files       %12d  (still billed at the class minimum)\n", zero
		printf "\n"

		if (show_hist == "true") {
			printf "  Size distribution\n"
			printf "  %-17s %9s %12s\n", "", "files", "bytes"
			for (i = 1; i <= nbuck; i++) {
				if (bcount[i] == 0) continue
				printf "  %-17s %9d %12s  %s\n", blab[i], bcount[i], hb(bbytes[i]), bar(bcount[i] / n)
			}
			printf "\n"
		}

		printf "================================================================\n"
		printf " Monthly storage cost, single class for everything\n"
		printf "================================================================\n"
		printf "  %-15s %11s %12s %9s %10s %11s\n", \
			"class", "storage/mo", "billable", "waste", "seed PUTs", "min days"
		for (c = 1; c <= NC; c++) {
			cls = CL[c]
			waste = (bytes > 0) ? 100 * (billb[cls] - bytes) / bytes : 0
			putc = n / 1000 * put[cls]
			printf "  %-15s %11s %12s %8.1f%% %10s %11s\n", \
				cls, money(total[cls]), hb(billb[cls]), waste, money(putc), \
				(mind[cls] ? mind[cls] : "-")
		}
		printf "\n"
		printf "  \"waste\" is billable bytes above real bytes: the minimum object size\n"
		printf "  (128 KiB for IA and GLACIER_IR) and the 40 KiB per-object overhead on\n"
		printf "  GLACIER and DEEP_ARCHIVE. It is what makes archive tiers expensive for\n"
		printf "  small files.\n\n"

		printf "================================================================\n"
		printf " Monthly storage cost, small files split off to STANDARD\n"
		printf "================================================================\n"
		printf "  %-15s %11s %11s %9s  %s\n", \
			"archive class", "storage/mo", "vs single", "saving", "optimal threshold"
		best = ""; bestv = -1
		for (c = 2; c <= NC; c++) {
			cls = CL[c]
			sv = total[cls] - split_total[cls]
			pc = (total[cls] > 0) ? 100 * sv / total[cls] : 0
			edge = split_edge[cls]
			printf "  %-15s %11s %11s %8.1f%%  %s (%d files below)\n", \
				cls, money(split_total[cls]), money(total[cls]), pc, \
				(split_small_n[cls] > 0 ? hb(edge + 1) : "n/a"), split_small_n[cls]
			if (bestv < 0 || split_total[cls] < bestv) { bestv = split_total[cls]; best = cls }
		}
		printf "\n"

		# --- request costs -------------------------------------------------
		lists = (int(n / 1000) + 1)
		list_cost = lists / 1000 * p_list
		churn_n = n * churn / 100
		printf "================================================================\n"
		printf " Request cost per weekly run\n"
		printf "================================================================\n"
		printf "  Destination LIST (%d pages)                       %11s\n", lists, money(list_cost)
		printf "  Re-uploads at %.1f%% churn (%d objects, %s)   %11s\n", \
			churn, churn_n, best, money(churn_n / 1000 * put[best])
		printf "\n"
		printf "  Comparison strategy (COMPARE_MODE), per run:\n"
		printf "    server-modtime / size-only   LIST only                 %11s\n", money(list_cost)
		printf "    modtime (rclone default)     1 HEAD per object         %11s   in STANDARD\n", \
			money(list_cost + n / 1000 * getp["STANDARD"])
		printf "                                                           %11s   in GLACIER_IR\n", \
			money(list_cost + n / 1000 * getp["GLACIER_IR"])
		printf "\n"
		printf "  That last line is why COMPARE_MODE defaults to server-modtime. A HEAD\n"
		printf "  per object per run is billed at the GET rate, and the GET rate for\n"
		printf "  GLACIER_IR is 25x STANDARD. Over 52 runs that is %s a year.\n\n", \
			money(52 * n / 1000 * getp["GLACIER_IR"])

		# --- restore -------------------------------------------------------
		gbytes = bytes / GB
		egress = (gbytes > 100 ? (gbytes - 100) * p_egress : 0)
		printf "================================================================\n"
		printf " Cost of restoring all %s, once\n", hb(bytes)
		printf "================================================================\n"
		printf "  %-15s %12s %12s %12s  %s\n", "class", "retrieval", "egress", "total", "wait"
		for (c = 1; c <= NC; c++) {
			cls = CL[c]
			r = gbytes * retr[cls]
			wait = "instant"
			if (cls == "GLACIER") wait = "3-5 h (bulk 5-12 h)"
			if (cls == "DEEP_ARCHIVE") wait = "12 h (bulk 48 h)"
			printf "  %-15s %12s %12s %12s  %s\n", cls, money(r), money(egress), money(r + egress), wait
		}
		printf "\n  Egress assumes the 100 GB/month free allowance. Restoring to an EC2\n"
		printf "  instance in the same region is free; restoring to the NAS is not.\n\n"

		# --- yearly totals --------------------------------------------------
		printf "================================================================\n"
		printf " First-year total, small-file split, %.1f%% churn/run, %d full restore(s)\n", churn, restores
		printf "================================================================\n"
		printf "  %-15s %13s %13s %13s\n", "archive class", "storage/yr", "requests/yr", "TOTAL yr 1"
		for (c = 2; c <= NC; c++) {
			cls = CL[c]
			st = split_total[cls] * 12
			seed = n / 1000 * put[cls]
			req = seed + 52 * (list_cost + churn_n / 1000 * put[cls])
			res = restores * (gbytes * retr[cls] + egress)
			printf "  %-15s %13s %13s %13s%s\n", cls, money(st), money(req), money(st + req + res), \
				(cls == best ? "   <- cheapest" : "")
		}
		printf "\n"

		# --- verdict --------------------------------------------------------
		printf "================================================================\n"
		printf " Recommendation\n"
		printf "================================================================\n"
		printf "  STORAGE_CLASS=%s\n", best
		printf "  SMALL_FILE_CLASS=STANDARD\n"
		printf "  SMALL_FILE_THRESHOLD=%d   (%s)\n", split_edge[best] + 1, hb(split_edge[best] + 1)
		printf "\n"
		printf "  Currently configured: STORAGE_CLASS=%s SMALL_FILE_CLASS=%s COMPARE_MODE=%s\n", \
			cur_class, cur_small, cur_mode
		if (mind[best] >= 90) {
			printf "\n  %s bills a minimum of %d days per object. Only point it at data\n", best, mind[best]
			printf "  that does not change: re-uploading a file weekly into a %d-day class\n", mind[best]
			printf "  pays for it %d times over. Keep working directories on GLACIER_IR or\n", int(mind[best] / 7)
			printf "  STANDARD in a separate job.\n"
		}
		printf "\n  These are list prices from nasbak.conf, not a quote. Set a billing\n"
		printf "  alarm before the first full seed.\n\n"
	}
	' "$_sizes"
}
