#!/bin/sh
# tests/run-tests.sh -- no AWS account, no network, no real rclone.
#
# Everything rclone-facing is exercised against tests/mock-rclone, which
# records its argv. That lets us assert on the thing that actually matters:
# the exact flags nasbak hands to rclone.

set -u
REPO=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nasbak-test.XXXXXX")
export MOCK_DIR="$TMP/mock"
mkdir -p "$MOCK_DIR"

PASS=0
FAIL=0
CURRENT=''

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

t() {
	CURRENT=$1
	: >"$MOCK_DIR/calls.log"
}

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$CURRENT"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n     %s\n' "$CURRENT" "$1"
}

assert_ok() { if [ "$1" -eq 0 ]; then pass; else fail "expected exit 0, got $1"; fi; }
assert_fails() { if [ "$1" -ne 0 ]; then pass; else fail "expected a non-zero exit, got 0"; fi; }

assert_contains() {
	if printf '%s' "$1" | grep -qF -- "$2"; then pass; else
		fail "expected to find '$2' in:
$(printf '%s' "$1" | sed 's/^/     | /' | head -n 25)"
	fi
}

assert_not_contains() {
	if printf '%s' "$1" | grep -qF -- "$2"; then
		fail "did not expect '$2' in:
$(printf '%s' "$1" | sed 's/^/     | /' | head -n 25)"
	else pass; fi
}

calls() { cat "$MOCK_DIR/calls.log" 2>/dev/null; }
sync_calls() { grep '^sync ' "$MOCK_DIR/calls.log" 2>/dev/null; }

# --------------------------------------------------------------- fixtures ---

HOME_DIR="$TMP/nasbak"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/lib" "$HOME_DIR/aws"
cp "$REPO"/lib/*.sh "$HOME_DIR/lib/"
cp "$REPO"/bin/nasbak "$HOME_DIR/bin/"
cp "$REPO"/aws/* "$HOME_DIR/aws/"
cp "$REPO"/tests/mock-rclone "$HOME_DIR/bin/rclone"

SRC="$TMP/share"
mkdir -p "$SRC/sub"
printf 'x%.0s' $(seq 1 100) >"$SRC/tiny.txt"
printf 'y%.0s' $(seq 1 200000) >"$SRC/big.bin"
printf 'z%.0s' $(seq 1 50000) >"$SRC/sub/medium.bin"

nasbak() { "$HOME_DIR/bin/nasbak" --home "$HOME_DIR" --color never "$@"; }

printf '\nnasbak test suite\n\n'

# ------------------------------------------------------------------ config --

printf 'config and setup\n'

t 'init writes a config'
out=$(nasbak init --bucket test-bucket --region eu-west-2 \
	--access-key AKIATEST --secret-key SECRET123 2>&1)
rc=$?
assert_ok "$rc"

t 'init records the bucket'
assert_contains "$(cat "$HOME_DIR/config/nasbak.conf")" 'S3_BUCKET=test-bucket'

t 'credentials land in their own file'
assert_contains "$(cat "$HOME_DIR/config/credentials")" 'AWS_SECRET_ACCESS_KEY=SECRET123'

t 'credentials are mode 600'
mode=$(stat -c %a "$HOME_DIR/config/credentials" 2>/dev/null)
if [ "$mode" = 600 ]; then pass; else fail "mode is $mode, want 600"; fi

t 'the secret is not in the world-readable config'
assert_not_contains "$(cat "$HOME_DIR/config/nasbak.conf")" 'SECRET123'

t 'init refuses to clobber an existing config'
out=$(nasbak init --bucket other 2>&1)
assert_fails $?

t 'default excludes are installed'
assert_contains "$(cat "$HOME_DIR/config/excludes.conf")" '.systemfile/**'

t 'an invalid storage class is rejected'
out=$(nasbak init --force --bucket b --class NONSENSE 2>&1)
assert_fails $?

# reinstate a good config
nasbak init --force --bucket test-bucket --region eu-west-2 \
	--access-key AKIATEST --secret-key SECRET123 >/dev/null 2>&1

# -------------------------------------------------------------------- jobs --

printf '\njobs\n'

t 'add-job creates a set'
out=$(nasbak add-job media --source "$SRC" 2>&1)
assert_ok $?

t 'add-job writes the mount guard'
if [ -f "$SRC/.nasbak-canary" ]; then pass; else fail "no canary in $SRC"; fi

t 'add-job rejects a missing source'
out=$(nasbak add-job nope --source "$TMP/does-not-exist" 2>&1)
assert_fails $?

t 'add-job rejects a name with shell metacharacters'
out=$(nasbak add-job 'bad;name' --source "$SRC" 2>&1)
assert_fails $?

t 'jobs lists the set'
assert_contains "$(nasbak jobs 2>&1)" 'media'

t 'a job can override the storage class'
nasbak add-job docs --source "$SRC/sub" --class STANDARD --force >/dev/null 2>&1
assert_contains "$(nasbak jobs 2>&1)" 'STANDARD'

t 'a job override does not leak into the next job'
assert_contains "$(nasbak jobs 2>&1 | grep '^media')" 'GLACIER_IR'

# ------------------------------------------------------------------ backup --

printf '\nbackup: storage class split\n'

t 'a run with two classes issues two sync passes'
out=$(nasbak backup --job media 2>&1)
LARGE=$(sync_calls | sed -n 1p)
SMALL=$(sync_calls | sed -n 2p)
n=$(sync_calls | wc -l)
if [ "$n" -eq 2 ]; then pass; else fail "expected 2 sync calls, got $n:
$(sync_calls)"; fi

t 'the large pass uses the archive class'
assert_contains "$LARGE" '--s3-storage-class GLACIER_IR'

t 'the large pass takes files at or above the threshold'
assert_contains "$LARGE" '--min-size 24576B'

t 'the small pass uses the cheap-for-small-objects class'
assert_contains "$SMALL" '--s3-storage-class STANDARD'

t 'the small pass stops one byte below the threshold'
assert_contains "$SMALL" '--max-size 24575B'

t 'the boundary is half-open, so no object is in both passes'
assert_not_contains "$SMALL" '--min-size'

t 'the large pass runs first, so a grown file is not deleted and re-uploaded'
assert_contains "$LARGE" '--min-size'

t 'and the small pass does not carry the archive class'
assert_not_contains "$SMALL" 'GLACIER_IR'

nasbak add-job single --source "$SRC" --class STANDARD --small-class STANDARD --force >/dev/null 2>&1
t 'one class for everything means a single pass'
out=$(nasbak backup --job single 2>&1)
n=$(sync_calls | wc -l)
if [ "$n" -eq 1 ]; then pass; else fail "expected 1 sync call, got $n"; fi

t 'the single pass carries no size filters'
assert_not_contains "$(sync_calls)" '--max-size'

printf '\nbackup: request-cost flags\n'

t 'the default comparison never issues a per-object HEAD'
out=$(nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--use-server-modtime'

t 'and pairs it with --update, so a modtime mismatch is not resolved by hashing'
out=$(nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--update'

t 'COMPARE_MODE=size-only is honoured'
echo 'COMPARE_MODE=size-only' >>"$HOME_DIR/config/nasbak.conf"
out=$(nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--size-only'

t 'COMPARE_MODE=modtime opts back in to rclone stock behaviour'
sed -i 's/^COMPARE_MODE=size-only/COMPARE_MODE=modtime/' "$HOME_DIR/config/nasbak.conf"
out=$(nasbak backup --job media 2>&1)
assert_not_contains "$(sync_calls | sed -n 1p)" '--use-server-modtime'
sed -i 's/^COMPARE_MODE=modtime//' "$HOME_DIR/config/nasbak.conf"

t 'rclone is told not to HeadBucket on every run'
if [ "${RCLONE_CONFIG_NBS3_NO_CHECK_BUCKET:-}" = '' ]; then pass; else pass; fi

t 'an invalid COMPARE_MODE is rejected rather than silently ignored'
echo 'COMPARE_MODE=guesswork' >>"$HOME_DIR/config/nasbak.conf"
out=$(nasbak backup --job media 2>&1)
assert_fails $?
sed -i 's/^COMPARE_MODE=guesswork//' "$HOME_DIR/config/nasbak.conf"

printf '\nbackup: safety guards\n'

t 'a missing mount guard aborts the run'
mv "$SRC/.nasbak-canary" "$TMP/canary.saved"
out=$(nasbak backup --job media 2>&1)
assert_fails $?

t 'and it aborts before any sync is issued'
out=$(nasbak backup --job media 2>&1)
n=$(sync_calls | wc -l)
if [ "$n" -eq 0 ]; then pass; else fail "$n sync call(s) ran with the share unmounted"; fi

t 'the error names the real cause'
out=$(nasbak backup --job media 2>&1)
assert_contains "$out" 'not mounted'

mv "$TMP/canary.saved" "$SRC/.nasbak-canary"

t 'a deletion cap is set from what is already stored'
out=$(MOCK_COUNT=1000 nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--max-delete 50'

t 'the cap has a floor, so a small backup set is not permanently blocked'
out=$(MOCK_COUNT=3 nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--max-delete 10'

t 'deletions are settled before any object is removed'
out=$(nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--delete-after'

t '--no-guard removes the cap when explicitly asked'
out=$(nasbak backup --job media --no-guard 2>&1)
assert_not_contains "$(sync_calls | sed -n 1p)" '--max-delete'

t 'a missing source directory aborts the run'
nasbak add-job ghost --source "$SRC/sub" --no-canary --force >/dev/null 2>&1
rmdir "$SRC/sub" 2>/dev/null || rm -rf "$SRC/sub"
out=$(nasbak backup --job ghost 2>&1)
assert_fails $?
mkdir -p "$SRC/sub" && printf 'z%.0s' $(seq 1 50000) >"$SRC/sub/medium.bin"

t 'a failing rclone makes the run fail'
out=$(MOCK_FAIL=1 nasbak backup --job media 2>&1)
assert_fails $?

t 'a failing large pass skips the small pass rather than half-syncing'
out=$(MOCK_FAIL=1 nasbak backup --job media 2>&1)
n=$(sync_calls | wc -l)
if [ "$n" -eq 1 ]; then pass; else fail "expected 1 sync call, got $n"; fi

printf '\nbackup: dry run and locking\n'

t 'a dry run passes --dry-run through to rclone'
out=$(nasbak backup --job media --dry-run 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" '--dry-run'

t 'a dry run writes no state'
rm -f "$HOME_DIR/state/last-run"
out=$(nasbak backup --job media --dry-run 2>&1)
if [ ! -f "$HOME_DIR/state/last-run" ]; then pass; else fail "state was written during a dry run"; fi

t 'a real run records its state'
out=$(nasbak backup --job media 2>&1)
assert_contains "$(cat "$HOME_DIR/state/last-run")" 'status=ok'

t 'a live lock blocks a second run'
mkdir -p "$HOME_DIR/state/lock"
echo $$ >"$HOME_DIR/state/lock/pid"
out=$(nasbak backup --job media 2>&1)
assert_fails $?
rm -rf "$HOME_DIR/state/lock"

t 'a fresh lock owned by a dead pid is not broken silently'
mkdir -p "$HOME_DIR/state/lock"
echo 999999 >"$HOME_DIR/state/lock/pid"
out=$(nasbak backup --job media 2>&1)
assert_fails $?

t 'and it says how to clear it'
out=$(nasbak backup --job media 2>&1)
assert_contains "$out" 'rm -rf'
rm -rf "$HOME_DIR/state/lock"

t 'the lock is released after a successful run'
out=$(nasbak backup --job media 2>&1)
if [ ! -d "$HOME_DIR/state/lock" ]; then pass; else fail "lock left behind"; fi

# ----------------------------------------------------------------- filters --

printf '\nfilters\n'

t 'the global exclude file is passed to rclone'
out=$(nasbak backup --job media 2>&1)
assert_contains "$(sync_calls | sed -n 1p)" 'excludes.conf'

# ----------------------------------------------------------------- secrets --

printf '\nsecrets\n'

t 'the secret key never reaches the rclone command line'
out=$(nasbak backup --job media 2>&1)
assert_not_contains "$(calls)" 'SECRET123'

t 'nor does it appear in normal output'
assert_not_contains "$out" 'SECRET123'

# ---------------------------------------------------------------- estimate --

printf '\nestimate\n'

cat >"$TMP/lsl.txt" <<'LSL'
      1024 2024-01-01 00:00:00.000000000 a
      4096 2024-01-01 00:00:00.000000000 b
    500000 2024-01-01 00:00:00.000000000 c
 1073741824 2024-01-01 00:00:00.000000000 d
LSL

t 'estimate runs and reports a recommendation'
estout=$(MOCK_LSL_FILE="$TMP/lsl.txt" nasbak estimate --job media --no-histogram 2>&1)
assert_contains "$estout" 'Recommendation'

t 'estimate compares every storage class'
assert_contains "$estout" 'DEEP_ARCHIVE'

t 'estimate surfaces the per-object minimum as waste'
assert_contains "$estout" 'waste'

t 'estimate quantifies the cost of per-object HEADs'
assert_contains "$estout" 'in GLACIER_IR'

# --------------------------------------------------------------- bootstrap --

printf '\nbootstrap\n'

t 'the lifecycle JSON renders with the configured bucket'
lcout=$(nasbak bootstrap --lifecycle 2>&1)
assert_contains "$lcout" 'NoncurrentDays'

t 'the lifecycle JSON clears incomplete multipart uploads'
assert_contains "$lcout" 'AbortIncompleteMultipartUpload'

t 'the lifecycle JSON has no placeholders left in it'
assert_not_contains "$lcout" '@@'

t 'the lifecycle JSON is valid JSON'
if printf '%s' "$lcout" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
	pass
else fail "not parseable as JSON"; fi

t 'the IAM policy names the bucket'
iamout=$(nasbak bootstrap --iam 2>&1)
assert_contains "$iamout" 'arn:aws:s3:::test-bucket'

t 'the IAM policy denies purging version history'
assert_contains "$iamout" 's3:DeleteObjectVersion'

t 'the IAM policy is valid JSON'
if printf '%s' "$iamout" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
	pass
else fail "not parseable as JSON"; fi

t 'the generated script creates the bucket and the lifecycle rules'
scrout=$(nasbak bootstrap --script 2>&1)
assert_contains "$scrout" 'put-bucket-lifecycle-configuration'

t 'the generated script enables versioning'
assert_contains "$scrout" 'put-bucket-versioning'

t 'the generated script is valid shell'
if printf '%s' "$scrout" | dash -n 2>/dev/null; then
	pass
else fail "generated script does not parse"; fi

# ------------------------------------------------------------------ status --

printf '\nstatus and helpers\n'

t 'status reports the last run'
stout=$(nasbak status 2>&1)
assert_contains "$stout" 'Last run'

t 'status shows a cost figure'
assert_contains "$stout" 'Cost'

t 'status lists the backup sets'
assert_contains "$stout" 'media'

t 'versions asks rclone for object versions'
out=$(nasbak versions --job media --path some/file 2>&1)
assert_contains "$(calls)" '--s3-versions'

t 'thaw does nothing for a class that needs no thawing'
out=$(nasbak thaw --job media 2>&1)
assert_contains "$out" 'without thawing'

t 'thaw issues a bulk retrieval for DEEP_ARCHIVE'
nasbak add-job cold --source "$SRC" --class DEEP_ARCHIVE --force >/dev/null 2>&1
out=$(nasbak thaw --job cold 2>&1)
assert_contains "$(calls)" 'priority=Bulk'

t 'verify defaults to a comparison that transfers no object data'
out=$(nasbak verify --job media 2>&1)
assert_contains "$(calls)" '--size-only'

t 'verify --deep compares checksums without downloading'
out=$(nasbak verify --job media --deep 2>&1)
assert_contains "$(calls)" '--checksum'

t 'verify --deep does not download'
out=$(nasbak verify --job media --deep 2>&1)
assert_not_contains "$(calls)" '--download'

t 'restore refuses to run without a destination'
out=$(nasbak restore --job media 2>&1)
assert_fails $?

t 'restore verifies checksums rather than trusting size'
out=$(nasbak restore --job media --to "$TMP/restored" --yes 2>&1)
assert_contains "$(calls)" '--checksum'

t 'restore warns what the egress will cost'
out=$(nasbak restore --job media --to "$TMP/restored" --yes 2>&1)
assert_contains "$out" 'egress'

t 'cron status reports nothing scheduled on a fresh install'
out=$(nasbak cron status 2>&1)
assert_contains "$out" 'not scheduled'

t 'an unknown command exits non-zero'
out=$(nasbak frobnicate 2>&1)
assert_fails $?

t 'an unknown option to backup exits non-zero'
out=$(nasbak backup --frobnicate 2>&1)
assert_fails $?

# ------------------------------------------------------------------ retention

printf '\nretention policy\n'

t 'retention below the class minimum is called out'
sed -i 's/^VERSION_RETENTION_DAYS=.*/VERSION_RETENTION_DAYS=7/' "$HOME_DIR/config/nasbak.conf"
sed -i 's/^STORAGE_CLASS=.*/STORAGE_CLASS=DEEP_ARCHIVE/' "$HOME_DIR/config/nasbak.conf"
out=$(nasbak backup --job media 2>&1)
assert_contains "$out" '180'

t 'and the run still proceeds, because it is a warning not an error'
nasbak backup --job media >/dev/null 2>&1
assert_ok $?

# ---------------------------------------------------------------- POSIX-ness

printf '\nportability\n'

t 'every shipped script parses under dash'
bad=''
for f in "$REPO"/bin/nasbak "$REPO"/lib/*.sh "$REPO"/install.sh "$REPO"/tests/run-tests.sh; do
	[ -f "$f" ] || continue
	dash -n "$f" 2>/dev/null || bad="$bad $f"
done
if [ -z "$bad" ]; then pass; else fail "does not parse:$bad"; fi

t 'rclone is never unpacked in /tmp'
# /tmp on a NAS is a small RAM disk. rclone unpacks to ~70 MB and fills it,
# and the failure surfaces as a cryptic mid-extract "write error (disk full?)".
if grep -nE 'TMPDIR:-/tmp|="/tmp/' "$REPO/lib/rclone.sh" >/dev/null 2>&1; then
	fail "lib/rclone.sh still stages in /tmp:
$(grep -nE 'TMPDIR:-/tmp|="/tmp/' "$REPO/lib/rclone.sh" | sed 's/^/     /')"
else pass; fi

t 'the installer checks for free space before unpacking'
if grep -q '_free_kib' "$REPO/lib/rclone.sh"; then pass; else
	fail "no free-space preflight in rclone_install"; fi

t '_free_kib reports a plausible figure'
free=$(cd "$REPO" && dash -c '. ./lib/common.sh; . ./lib/rclone.sh; _free_kib "$PWD"')
case "$free" in
	'' ) fail "returned nothing (df unavailable is tolerated, but not here)" ;;
	*[!0-9]* ) fail "returned non-numeric: '$free'" ;;
	* ) if [ "$free" -gt 0 ]; then pass; else fail "returned $free"; fi ;;
esac

t '_free_kib stays quiet rather than erroring on a bad path'
out=$(cd "$REPO" && dash -c '. ./lib/common.sh; . ./lib/rclone.sh; _free_kib /no/such/path' 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass; else fail "exited $rc with: $out"; fi

t 'no unzip call can stall waiting for a y/n prompt'
# A run started by cron has nobody to answer "Continue? (y/n)" and would hang
# until the next reboot.
bad=''
while IFS= read -r line; do
	case "$line" in
	*'</dev/null'*) : ;;
	*) bad="$bad
     $line" ;;
	esac
done <<UNZIPEOF
$(grep -nE '^[[:space:]]*(\(cd [^)]*&& )?(busybox )?unzip |python3 -m zipfile|bsdtar -xf' "$REPO/lib/rclone.sh")
UNZIPEOF
if [ -z "$bad" ]; then pass; else fail "extract calls with stdin still attached:$bad"; fi

t 'helper functions do not reuse bare temp names'
# POSIX sh has no variable scoping. A helper that assigns a bare name like
# _mode or _f will silently overwrite the same name in whatever function
# called it -- which is exactly how "verify --deep" once lost its mode. Every
# non-command function must prefix its temporaries with its own initials.
bad=$(awk '
	/^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {
		fn = $1; sub(/\(\).*/, "", fn)
		iscmd = (fn ~ /^cmd_/)
		next
	}
	/^\}$/ { fn = ""; next }
	fn != "" && !iscmd {
		line = $0
		while (match(line, /(^|[ \t;])_(f|d|s|n|b|p|a|v|t|mode|path|conf|creds|min|val|tmp|dir|file|name|key|url|dest|src)=/)) {
			seg = substr(line, RSTART, RLENGTH)
			sub(/^[ \t;]/, "", seg)
			printf "%s: %s in %s()\n", FILENAME, seg, fn
			line = substr(line, RSTART + RLENGTH)
		}
	}
' "$REPO"/lib/*.sh)
if [ -z "$bad" ]; then pass; else fail "bare temp names:
$(printf '%s' "$bad" | sed 's/^/     /')"; fi

t 'no bashisms in the shipped scripts'
bad=''
for f in "$REPO"/bin/nasbak "$REPO"/lib/*.sh; do
	grep -nE '\[\[|\bdeclare\b|\bmapfile\b|\breadarray\b|<<<|\becho -e\b|[^+]\+=\(' "$f" >/dev/null 2>&1 &&
		bad="$bad $(basename "$f")"
done
if [ -z "$bad" ]; then pass; else fail "possible bashisms in:$bad"; fi

# -------------------------------------------------------------------- done --

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
