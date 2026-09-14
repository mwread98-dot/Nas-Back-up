# Running this on a WD My Cloud EX2 Ultra

Everything here applies to the EX2 Ultra specifically; the EX2, EX4100, PR2100/PR4100
and DL-series are close enough that the same steps generally work. Nothing in `nasbak`
itself is model-specific.

---

## Enable SSH

**Dashboard → Settings → Network → SSH → On.** Set a password when prompted.

Then from your computer:

```sh
ssh sshd@<nas-ip>
```

The username is `sshd` on OS 5, `root` on older OS 3 firmware. Either way you land as
root.

> SSH is off by default for a reason. Leave it on the LAN — never forward port 22 from
> your router to the NAS.

## Find your shares

Shares live on the data volume. On an EX2 Ultra that is usually:

```sh
ls /mnt/HD/HD_a2/       # the real path
ls /shares/             # symlinks to the same thing on OS 5
```

Use the `/mnt/HD/HD_a2/...` paths in job definitions. `/shares` is a convenience
symlink and is not guaranteed to exist on every firmware.

```sh
nasbak add-job photos --source /mnt/HD/HD_a2/Photos
```

`install.sh` looks for `/mnt/HD/HD_a2`, `/mnt/HD_a2`, `/DataVolume`, `/shares`,
`/volume1` and `/mnt/data`, and installs to the first one it finds.

## Install

```sh
cd /mnt/HD/HD_a2
git clone https://github.com/mwread98-dot/Nas-Back-up.git
cd Nas-Back-up
./install.sh
```

No `git`? Download the zip on your computer, drop it in a share, and unzip it on the
NAS.

Everything lands on the **data volume**, on purpose. The EX2 Ultra's rootfs is a small
read-mostly partition with very little free space, and — more to the point — a firmware
update replaces it. Nothing you install under `/usr` or `/opt` survives one.

## What a firmware update breaks

The program, config, jobs and logs all live on the data volume and survive. Two things
do not:

1. **The cron entry** (`/etc/cron.d/nasbak`) — `/etc` is on the rootfs.
2. **The `/usr/local/bin/nasbak` symlink**, if you made one.

After any firmware update, SSH in and run:

```sh
/mnt/HD/HD_a2/nasbak/bin/nasbak cron ensure
```

`ensure` is idempotent — it reinstalls the schedule only if it has gone, using the
schedule it recorded when you first set it up. Safe to run any time.

If you set `HEALTHCHECK_URL`, you will get an email a day or two after the update
telling you the backup stopped running, which is how you remember to do this. That is
the entire point of the dead man's switch.

## Hardware realities

**CPU.** A Marvell Armada 385, dual-core ARMv7 at 1.3 GHz. `install.sh` fetches the
`linux-arm-v7` rclone build. TLS handshakes and checksums are the bottleneck, not the
network, on anything below about 200 Mbit upload.

**RAM.** 1 GB, shared with everything else the NAS is doing. The defaults are sized
for it:

```
TRANSFERS=2  S3_UPLOAD_CONCURRENCY=2  S3_CHUNK_SIZE=16M  BUFFER_SIZE=4M
```

Peak upload buffer is `TRANSFERS × S3_UPLOAD_CONCURRENCY × S3_CHUNK_SIZE` = 64 MiB.
Raising any of them multiplies that. `--fast-list` is deliberately *not* used above
`FAST_LIST_MAX_OBJECTS` (200,000) because it costs roughly 1 KB of RAM per object —
a million objects would try to allocate a gigabyte and take the NAS down with it.

16 MiB chunks also matter for a different reason: S3 caps a multipart upload at 10,000
parts, so 16 MiB gives a 160 GB ceiling per file. The 5 MiB default would cap it at
48 GB.

**Responsiveness.** Runs are `nice 15` and `ionice -c3` (idle), so streaming from the
NAS during a backup still works. Set `BWLIMIT` if uploads saturate your link:

```sh
BWLIMIT=5M                          # always cap at 5 MiB/s
BWLIMIT="08:00,1M 23:00,off"        # 1 MiB/s during the day, uncapped overnight
```

## Scheduling

```sh
nasbak cron install                      # Sunday 02:00
nasbak cron install --day 6 --hour 3     # Saturday 03:00
nasbak cron install --schedule "0 3 * * 1,4"   # Mondays and Thursdays
nasbak cron status
```

If the NAS is asleep at the scheduled time the run is simply missed — cron does not
catch up. Either disable sleep (**Settings → Power → Drive Sleep**) or pick a time you
know it is awake.

## The first run

Seeding is the slow part. A 1 TB share on a 40 Mbit upload link is roughly 2.5 days of
continuous transfer.

* It resumes. If it is interrupted, the next run picks up what is missing — rclone
  compares before it transfers.
* Run it inside `screen`, `tmux` or `nohup` so an SSH disconnect does not kill it:
  ```sh
  nohup /mnt/HD/HD_a2/nasbak/bin/nasbak backup > /tmp/seed.log 2>&1 &
  tail -f /tmp/seed.log
  ```
* Watch progress from a second session with `tail -f /mnt/HD/HD_a2/nasbak/logs/backup-*.log`.
* If your ISP has a data cap, set `BWLIMIT` and let it take a fortnight.

## Things that go wrong

**`nasbak check` can't reach S3.** Almost always the system clock — AWS rejects
requests whose signature is more than 15 minutes off.

```sh
date          # is it right?
ntpd -q -p pool.ntp.org
```

**A backup set fails preflight with "the share is probably not mounted".** Working as
designed: the canary file inside the share is missing, which usually means the volume
did not remount after a reboot. Check with `mount | grep HD_a2` and `ls /mnt/HD/HD_a2`.
If the share really is fine and you deleted the canary by accident:

```sh
nasbak canary photos
```

**`write error (disk full?)` while installing rclone.** Fixed in current versions,
which unpack on the data volume. If you are on an older copy, `/tmp` is a RAM disk of
a couple of hundred MB and rclone needs about 150 MB of it:

```sh
rm -rf /tmp/nasbak-rclone.*
export NASBAK_TMPDIR=/mnt/HD/HD_a2/nasbak/bin
nasbak install-rclone
```

**"Another nasbak run is active".** The previous weekly run has not finished — normal
during the initial seed. If nothing is really running:

```sh
ps | grep rclone
rm -rf /mnt/HD/HD_a2/nasbak/state/lock
```

**The NAS gets sluggish during backups.** Lower `TRANSFERS` to 1, or set `BWLIMIT`.

**Out of space on the rootfs.** Logs go to the data volume, so this is rarely `nasbak`.
Check `df -h` and look at `/var/log`.

## Alternative: run it somewhere else

If you would rather not install anything on the NAS — or you want the backup to survive
the NAS being compromised — run `nasbak` on a Raspberry Pi or any always-on Linux box
and point it at the shares over SMB or NFS:

```sh
mount -t cifs //nas.local/Photos /mnt/nas-photos -o ro,credentials=/root/.nascreds
nasbak add-job photos --source /mnt/nas-photos
```

Mount **read-only**, and keep `REQUIRE_CANARY=true` — an unmounted CIFS share looks
exactly like an empty directory, which is precisely the failure the canary exists to
catch. You can write the canary once from the NAS side, or mount read-write just long
enough to run `nasbak canary`.

This is the more robust arrangement. It also survives My Cloud firmware updates
entirely.
