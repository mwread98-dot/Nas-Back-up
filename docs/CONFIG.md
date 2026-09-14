# Configuration reference

Two files, both plain shell:

* `config/nasbak.conf` — global settings. Readable, diffable, safe to commit.
* `config/credentials` — the S3 key. Mode 600, never commit it.

Plus one `config/jobs.d/NAME.job` per backup set. Any setting marked *per-job* below
can be overridden there; anything left unset is inherited from `nasbak.conf`.

---

## Destination

| Setting | Default | |
|---|---|---|
| `S3_BUCKET` | — | Required. |
| `S3_REGION` | `us-east-1` | |
| `S3_PROVIDER` | `AWS` | `Wasabi`, `Minio`, `Ceph`, `Other`… |
| `S3_ENDPOINT` | — | For S3-compatible stores. Storage-class logic is AWS-specific. |
| `S3_ROOT_PREFIX` | — | Prefix shared by every set, if you share the bucket. |
| `S3_ENV_AUTH` | `false` | `true` to use `AWS_PROFILE` or an instance role. |
| `SSE` | `AES256` | `aws:kms` bills per request — see COSTS.md §7. |
| `SSE_KMS_KEY_ID` | — | Only with `SSE=aws:kms`. |

## Storage class *(per-job)*

| Setting | Default | |
|---|---|---|
| `STORAGE_CLASS` | `GLACIER_IR` | Class for large files. |
| `SMALL_FILE_CLASS` | `STANDARD` | Class for small ones. Set equal to `STORAGE_CLASS` to disable the two-pass split. |
| `SMALL_FILE_THRESHOLD` | `24k` | The boundary. `nasbak estimate` computes the optimum for your files. |

Valid classes: `STANDARD`, `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`,
`GLACIER_IR`, `GLACIER`, `DEEP_ARCHIVE`.

## Version history

| Setting | Default | |
|---|---|---|
| `VERSION_RETENTION_DAYS` | `90` | How long a superseded or deleted file stays recoverable. Matches the `GLACIER_IR` minimum duration, so nothing is billed early. |
| `KEEP_VERSIONS` | `3` | Floor on versions kept per file, regardless of age. Used when rendering the lifecycle policy. |
| `BACKUP_DIR_MODE` | `false` | Keep old versions under a dated `_versions/` prefix instead of relying on bucket versioning. Costs a server-side COPY per changed file; use only if you cannot enable versioning. |

Keep `VERSION_RETENTION_DAYS` at or above the class minimum (`GLACIER_IR`/`GLACIER` 90,
`DEEP_ARCHIVE` 180) or you pay an early-deletion charge on every expired version.
`nasbak check` warns.

## Comparison

| Setting | Default | |
|---|---|---|
| `COMPARE_MODE` | `server-modtime` | `server-modtime` \| `size-only` \| `checksum` \| `modtime` |

See COSTS.md §4 before changing this. `modtime` issues one `HEAD` per object per run,
which on `GLACIER_IR` costs about $84/year at 160,000 objects.

## Safety *(per-job)*

| Setting | Default | |
|---|---|---|
| `MAX_DELETE_PCT` | `5` | Abort if a run would delete more than this share of what is stored. |
| `MAX_DELETE_ABS` | `0` | Absolute floor on the cap. `0` = derive from the percentage. |
| `REQUIRE_CANARY` | `true` | Refuse to sync a share with no canary file. Do not turn this off. |
| `CANARY_NAME` | `.nasbak-canary` | |
| `MIN_SOURCE_FILES` | `1` | Refuse to sync a source that looks empty. |
| `LOCK_STALE_AFTER` | `86400` | Seconds before a lock whose owner is gone may be broken. |

The effective cap is `max(MAX_DELETE_ABS, MAX_DELETE_PCT% of stored objects)`, never
below 10. It is applied to each sync pass independently, so with the small-file split
active the worst case across a whole run is twice the percentage.

## Throughput

| Setting | Default | |
|---|---|---|
| `TRANSFERS` | `2` | Parallel file uploads. |
| `CHECKERS` | `8` | Parallel comparisons. Cheap. |
| `S3_CHUNK_SIZE` | `16M` | Multipart chunk. 16 MiB × 10,000 parts = 160 GB max file. |
| `S3_UPLOAD_CONCURRENCY` | `2` | Parallel chunks per file. |
| `BUFFER_SIZE` | `4M` | Read-ahead per transfer. |
| `BWLIMIT` | — | `5M`, or a schedule: `"08:00,1M 23:00,off"`. *(per-job)* |
| `TPSLIMIT` | — | Cap API calls per second. |
| `FAST_LIST` | `auto` | Fewer LIST calls, ~1 KB RAM per object. |
| `FAST_LIST_MAX_OBJECTS` | `200000` | Above this, `auto` declines. |
| `S3_NO_HEAD` | `false` | Skip the post-upload integrity check. Saves one request per upload; raises the chance of an undetected bad upload. Leave it off. |
| `RCLONE_EXTRA_ARGS` | — | Appended to every rclone invocation. |

Peak upload memory is `TRANSFERS × S3_UPLOAD_CONCURRENCY × S3_CHUNK_SIZE`. The defaults
come to 64 MiB, which is right for a 1 GB NAS.

## Politeness

| Setting | Default | |
|---|---|---|
| `USE_NICE` | `true` | |
| `NICE_LEVEL` | `15` | |
| `IONICE_CLASS` | `3` | 3 = idle. |

## Reporting

| Setting | Default | |
|---|---|---|
| `HEALTHCHECK_URL` | — | Dead man's switch. Pinged `/start`, then plain on success or `/fail`. Works with healthchecks.io and compatible services. |
| `NOTIFY_URL` | — | Webhook: ntfy, Gotify, Slack, Discord. |
| `NOTIFY_FORMAT` | `text` | `text` \| `slack` \| `discord`. |
| `NOTIFY_ON` | `fail` | `fail` \| `always` \| `never`. |
| `UPLOAD_RUN_REPORT` | `true` | Writes `_nasbak/last-run.json` into the bucket, so you can confirm the NAS is still backing up without being able to reach the NAS. |
| `LOG_KEEP` | `26` | Run logs retained. 26 weekly runs ≈ six months. |

Set `HEALTHCHECK_URL`. A backup that silently stopped running looks exactly like a
backup with nothing to do.

## Paths

| Setting | Default | |
|---|---|---|
| `NASBAK_HOME` | alongside `bin/nasbak` | |
| `CONFIG_DIR` | `$NASBAK_HOME/config` | |
| `JOBS_DIR` | `$CONFIG_DIR/jobs.d` | |
| `STATE_DIR` | `$NASBAK_HOME/state` | |
| `LOG_DIR` | `$NASBAK_HOME/logs` | |
| `RCLONE_BIN` | `$NASBAK_HOME/bin/rclone` | |
| `NASBAK_TMPDIR` | beside `RCLONE_BIN` | Where `install-rclone` unpacks. Never point this at `/tmp`: on a NAS that is a small RAM disk, and rclone unpacks to about 70 MB. |

## Pricing

`PRICE_GB_*`, `PRICE_PUT_*`, `PRICE_GET_*`, `PRICE_RETRIEVE_GB_*`, `PRICE_LIST_1K`,
`PRICE_EGRESS_GB`. Used only by `nasbak estimate` and the cost line in `nasbak status`.
Defaults are US East (N. Virginia) list prices — set them for your region if you want
the estimates to mean anything.

## Job files

```sh
# config/jobs.d/photos.job
SOURCE=/mnt/HD/HD_a2/Photos     # required
ENABLED=true
DEST_PREFIX=photos              # default: the job name
DESCRIPTION="Family photos"

STORAGE_CLASS=DEEP_ARCHIVE      # cold bulk
SMALL_FILE_CLASS=STANDARD
SMALL_FILE_THRESHOLD=10k

EXCLUDES=/mnt/HD/HD_a2/nasbak/config/jobs.d/photos.filter
MAX_DELETE_PCT=2
BWLIMIT=2M
```

Splitting by volatility is the single most valuable thing you can do with multiple
jobs — cold data into `DEEP_ARCHIVE`, anything that changes weekly into `GLACIER_IR`
or `STANDARD`. See COSTS.md §2.

## Filters

`config/excludes.conf` applies to every set; a job's `EXCLUDES` file applies to that
set only. Both use [rclone filter syntax](https://rclone.org/filtering/) — `- pattern`
excludes, `+ pattern` includes, first match wins.

The defaults exclude My Cloud internals (`.systemfile`, `.wdmc`, `.recycle_bin`),
macOS and Windows metadata, trash folders, and caches. Worth adding: VM disks and ISOs,
which are large, change constantly, and are the worst possible fit for an archive
storage class.
