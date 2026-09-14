#!/bin/sh
# install.sh -- put nasbak on the NAS.
#
# Installs to the DATA volume, never the rootfs. On a My Cloud the rootfs is
# small, and a firmware update replaces it wholesale; the data volume survives
# both.

set -eu

REPO=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-}
LINK=${LINK:-auto}
GET_RCLONE=${GET_RCLONE:-yes}

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

  --prefix DIR   Where to install. Default: a directory called nasbak on the
                 detected data volume, or /opt/nasbak.
  --no-rclone    Do not download rclone (you will supply it yourself).
  --no-link      Do not create a /usr/local/bin/nasbak symlink.
  -h, --help     This text.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--prefix) PREFIX=$2; shift 2 ;;
	--no-rclone) GET_RCLONE=no; shift ;;
	--no-link) LINK=no; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage; exit 2 ;;
	esac
done

say() { printf '  %s\n' "$*"; }

# Where does the bulk storage live? These are the layouts WD and friends use.
detect_data_volume() {
	for d in /mnt/HD/HD_a2 /mnt/HD_a2 /mnt/HD/HD_a4 /DataVolume /shares /volume1 /mnt/data; do
		[ -d "$d" ] && [ -w "$d" ] && { printf '%s' "$d"; return 0; }
	done
	return 1
}

if [ -z "$PREFIX" ]; then
	if vol=$(detect_data_volume); then
		PREFIX="$vol/nasbak"
		say "data volume detected at $vol"
	else
		PREFIX=/opt/nasbak
		say "no NAS data volume found; falling back to $PREFIX"
	fi
fi

printf '\nInstalling nasbak to %s\n\n' "$PREFIX"

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/aws" "$PREFIX/docs" \
	"$PREFIX/config/jobs.d" "$PREFIX/state" "$PREFIX/logs"

cp "$REPO/bin/nasbak" "$PREFIX/bin/nasbak"
chmod 755 "$PREFIX/bin/nasbak"
cp "$REPO"/lib/*.sh "$PREFIX/lib/"
cp "$REPO"/aws/* "$PREFIX/aws/"
[ -d "$REPO/docs" ] && cp "$REPO"/docs/*.md "$PREFIX/docs/" 2>/dev/null || :
[ -f "$REPO/README.md" ] && cp "$REPO/README.md" "$PREFIX/"
cp "$REPO"/config/*.example "$PREFIX/config/" 2>/dev/null || :
cp "$REPO"/config/jobs.d/*.example "$PREFIX/config/jobs.d/" 2>/dev/null || :
say "copied program files"

# Config and jobs are never overwritten by an upgrade.
if [ -f "$PREFIX/config/nasbak.conf" ]; then
	say "kept your existing config/nasbak.conf"
fi

if [ "$GET_RCLONE" = yes ]; then
	if [ -x "$PREFIX/bin/rclone" ]; then
		say "rclone already present: $("$PREFIX/bin/rclone" version | head -n 1)"
	else
		say "downloading rclone..."
		"$PREFIX/bin/nasbak" --home "$PREFIX" install-rclone || {
			echo
			echo "  rclone download failed. Install it by hand:" >&2
			echo "    https://rclone.org/downloads/  ->  $PREFIX/bin/rclone" >&2
			echo "  then re-run this script with --no-rclone." >&2
			exit 1
		}
	fi
fi

if [ "$LINK" = auto ] || [ "$LINK" = yes ]; then
	for d in /usr/local/bin /usr/bin; do
		if [ -d "$d" ] && [ -w "$d" ]; then
			ln -sf "$PREFIX/bin/nasbak" "$d/nasbak" && say "linked $d/nasbak"
			break
		fi
	done
fi

cat <<EOF

Installed.

  Program   $PREFIX/bin/nasbak
  Config    $PREFIX/config/
  Logs      $PREFIX/logs/

Next:

  $PREFIX/bin/nasbak init --bucket YOUR-BUCKET --region YOUR-REGION \\
      --access-key AKIA... --secret-key-stdin

  $PREFIX/bin/nasbak bootstrap --script > setup-s3.sh   # run on a workstation
  $PREFIX/bin/nasbak add-job photos --source /shares/Photos
  $PREFIX/bin/nasbak estimate          # what it will cost
  $PREFIX/bin/nasbak check             # does it all work
  $PREFIX/bin/nasbak backup --dry-run  # what the first run would do
  $PREFIX/bin/nasbak cron install      # weekly, Sunday 02:00

A firmware update wipes /etc, taking the cron entry with it. After one, run:

  $PREFIX/bin/nasbak cron ensure

EOF
