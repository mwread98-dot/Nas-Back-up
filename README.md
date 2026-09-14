# nasbak

Weekly NAS → S3 backup that keeps **one snapshot**, not a new full copy every month.

Built for a WD My Cloud EX2 Ultra, but it is POSIX `sh` plus [rclone](https://rclone.org),
so it runs on any NAS, Raspberry Pi or Linux box that can see the shares.

---

## The problem this fixes

The stock My Cloud S3 app uploads a fresh full copy on every scheduled run. After a
year you are paying to store twelve identical copies of the same holiday photos, and
there is no way to tell it to keep only the current one.

`nasbak` mirrors instead:

| | Stock My Cloud app | nasbak |
|---|---|---|
| Monthly run on unchanged data | Re-uploads everything | Uploads nothing |
| After 12 months of 1 TB | ~12 TB stored | 1 TB stored |
| Deleted file | Kept forever in old copies | Recoverable for N days, then gone |
| Storage class | S3 Standard | Straight into an archive class |
| Bill for 1 TB, 12 months |  ~$1,840 | **~$12–49** |

The last row is the whole point. Same data, same durability, two orders of magnitude
apart — because unchanged bytes are never re-uploaded and never re-stored, and because
the bytes that *are* stored go into a tier priced for archives.

## How it works

```
  NAS share ──rclone sync──▶  s3://bucket/photos/…   ← exactly one live object per file
                                      │
                                      ├── large files  → GLACIER_IR / DEEP_ARCHIVE
                                      └── small files  → STANDARD
                                      │
                              versioning + lifecycle
                                      │
                                      └── superseded versions expire after N days
```

* **`rclone sync`, not `copy`.** The bucket is a mirror of the NAS. A file that has not
  changed is not touched — no upload, no second copy, no charge.
* **Bucket versioning gives you the undo window.** Change or delete a file and the old
  version becomes *noncurrent*; a lifecycle rule expires it after `VERSION_RETENTION_DAYS`.
  Only changed files consume this, so it is nothing like a second full copy. It also
  means an accidental mass-delete is recoverable — see [Restoring](docs/RESTORE.md).
* **Files are PUT directly into their final storage class.** No lifecycle transitions,
  so no per-object transition charge and no mandatory 30 days in Standard first.
* **Small files go somewhere else.** Archive tiers bill a minimum of 128 KiB per object.
  A 4 KiB thumbnail in `GLACIER_IR` costs the same as a 128 KiB one — more than it costs
  in `STANDARD`. `nasbak` runs two passes with complementary size filters so each file
  lands in whichever tier is actually cheaper for its size.
* **Comparison is done from `LIST` metadata alone.** rclone's default is one `HEAD` per
  object per run to read the stored mtime. On `GLACIER_IR` a `HEAD` is billed at the GET
  rate — 25× Standard — so for 160,000 files that default costs about **$84/year in
  request charges alone**. `nasbak` avoids it entirely.

There is a command that shows you all of this arithmetic for *your* files:

```
$ nasbak estimate
```

<details>
<summary>Sample output for a 985 GiB / 160,900-file NAS</summary>

```
================================================================
 Monthly storage cost, single class for everything
================================================================
  class            storage/mo     billable     waste  seed PUTs    min days
  STANDARD             $22.65    984.8 GiB      0.0%     $0.804           -
  STANDARD_IA          $12.48    998.4 GiB      1.4%     $1.609          30
  GLACIER_IR           $3.994    998.4 GiB      1.4%     $3.218          90
  GLACIER              $3.591    991.0 GiB      0.6%     $4.827          90
  DEEP_ARCHIVE         $1.008    991.0 GiB      0.6%     $8.045         180

================================================================
 Request cost per weekly run
================================================================
  Comparison strategy (COMPARE_MODE), per run:
    server-modtime / size-only   LIST only                      $0.0008
    modtime (rclone default)     1 HEAD per object               $0.065   in STANDARD
                                                                 $1.610   in GLACIER_IR

================================================================
 Recommendation
================================================================
  STORAGE_CLASS=DEEP_ARCHIVE
  SMALL_FILE_CLASS=STANDARD
  SMALL_FILE_THRESHOLD=10035   (9.8 KiB)
```

</details>

## Install

SSH into the NAS ([how, on a My Cloud](docs/MYCLOUD.md)), then:

```sh
git clone https://github.com/mwread98-dot/Nas-Back-up.git
cd Nas-Back-up
./install.sh
```

The installer puts everything on the **data volume**, never the rootfs — the My Cloud
rootfs is small and a firmware update replaces it wholesale. It also downloads the
right rclone build for your CPU and checks it against the published SHA256.

## Set up

**1. Create the S3 side.** Either the CloudFormation template:

```sh
aws cloudformation deploy --stack-name nas-backup \
  --template-file aws/cloudformation.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides BucketName=your-nas-backup-7f3a NotificationEmail=you@example.com
```

…or generate a plain shell script and read it before running it:

```sh
nasbak bootstrap --script > setup-s3.sh
```

Either way you get a private, encrypted, versioned bucket, the lifecycle rules, and a
least-privilege IAM user whose key **cannot delete version history** — so a compromised
NAS can't destroy the backup.

**2. Configure the NAS.**

```sh
nasbak init --bucket your-nas-backup-7f3a --region eu-west-2 \
    --access-key AKIA... --secret-key-stdin

nasbak add-job photos --source /shares/Photos
nasbak add-job documents --source /shares/Documents --class GLACIER_IR
```

**3. Check the cost and the plumbing, then schedule it.**

```sh
nasbak estimate           # what will this cost, given my actual files
nasbak check              # can I reach S3, is everything mounted, is cron set
nasbak backup --dry-run   # what would the first run do
nasbak cron install       # weekly, Sunday 02:00
```

The first run uploads everything and will take a while — a My Cloud EX2 Ultra on a
typical home upload link manages roughly 40–80 GB/day. Every run after that only moves
what changed.

## Day to day

```sh
nasbak status            # last run, what is stored, roughly what it costs
nasbak status --live     # ...and ask S3 for the real current numbers
nasbak verify            # does S3 match the NAS
nasbak backup            # run now, off-schedule
```

## Getting data back

```sh
nasbak versions --job photos --path 2019/italy/DSC_0042.jpg
nasbak restore --job photos --to /shares/Restored --path 2019/italy
nasbak restore --job photos --to /shares/Restored --at 2025-08-01   # point in time
```

`--at` reads the bucket as it was on that date, so it recovers files that have since
been deleted or overwritten — as long as you are inside the retention window. If the
data is in `GLACIER` or `DEEP_ARCHIVE`, thaw it first with `nasbak thaw`.

Full walkthrough, including the ransomware and accidental-`rm -rf` cases:
**[docs/RESTORE.md](docs/RESTORE.md)**.

## Safety

A mirror propagates deletions, which is exactly what you want until the day a share
fails to remount and the mount point is left as an empty directory. Three independent
brakes:

1. **Mount guard.** Each backup set keeps a canary file inside the share. No canary,
   no sync — an unmounted share can't be mistaken for an empty one.
2. **Deletion cap.** A run that would remove more than `MAX_DELETE_PCT` of what is
   already stored aborts instead. Deletions are also deferred to the end of the run,
   after the uploads.
3. **Versioning.** Even if something does delete everything, the objects become
   noncurrent versions rather than disappearing, and `nasbak restore --at` brings them
   back. The NAS's IAM policy explicitly cannot purge them.

Plus a dead man's switch: set `HEALTHCHECK_URL` and you get an email when a backup
*doesn't* run. A backup that silently stopped looks identical to one with nothing to do.

## Commands

| | |
|---|---|
| `init` · `add-job` · `jobs` · `canary` | configuration |
| `install-rclone` · `bootstrap` · `cron` · `check` | setup |
| `backup` · `status` · `estimate` · `verify` · `prune` | running |
| `versions` · `thaw` · `restore` | getting data back |

Everything takes `--help`.

## Documentation

* **[docs/COSTS.md](docs/COSTS.md)** — every cost decision, with the arithmetic. Read
  this before changing `STORAGE_CLASS`.
* **[docs/MYCLOUD.md](docs/MYCLOUD.md)** — EX2 Ultra specifics: SSH, share paths,
  surviving firmware updates.
* **[docs/RESTORE.md](docs/RESTORE.md)** — getting data back, including disaster cases.
* **[docs/CONFIG.md](docs/CONFIG.md)** — every setting.

## Requirements

* A NAS you can SSH into, with `sh`, `curl` (or `wget`), `find`, `awk` and `sed`.
* rclone 1.55+ — `install.sh` fetches it.
* An AWS account. Works with any S3-compatible store (Wasabi, Backblaze B2, MinIO) via
  `S3_ENDPOINT`, though the storage-class logic is AWS-specific.

## Tests

```sh
sh tests/run-tests.sh
```

85 tests, no AWS account and no network needed — rclone is mocked so the suite can
assert on the exact flags nasbak generates.

## Licence

MIT.
