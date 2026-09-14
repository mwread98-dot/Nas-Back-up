# Where the money goes

Every cost decision in `nasbak`, with the arithmetic. Prices are US East
(N. Virginia) list prices and live in `PRICE_*` in `nasbak.conf` — change them for
your region. `nasbak estimate` runs all of this against your real file sizes.

---

## 1. Store one copy, not twelve

This is the big one, and it is the bug in the stock My Cloud app.

A full copy each month, all copies retained, 1 TB of data, S3 Standard:

| Month | Stored | Bill |
|---|---|---|
| 1 | 1 TB | $24 |
| 6 | 6 TB | $141 |
| 12 | 12 TB | $283 |
| **Year 1 total** | | **$1,837** |

`rclone sync` mirrors instead. One live object per file; unchanged files are not
re-uploaded and not re-stored. 1 TB stays 1 TB:

| Class | Per month | Year 1 |
|---|---|---|
| STANDARD | $23.55 | $283 |
| GLACIER_IR | $4.10 | $49 |
| DEEP_ARCHIVE | $1.01 | $12 |

Everything below is a rounding error next to this. Get this right first.

## 2. Pick the class by what the data *is*

| Class | $/GB-mo | Min object | Min duration | First byte back |
|---|---|---|---|---|
| STANDARD | 0.023 | — | — | instant |
| STANDARD_IA | 0.0125 | 128 KiB | 30 days | instant |
| GLACIER_IR | 0.004 | 128 KiB | 90 days | instant |
| GLACIER | 0.0036 | 40 KiB overhead | 90 days | 3–5 h (bulk 5–12 h) |
| DEEP_ARCHIVE | 0.00099 | 40 KiB overhead | 180 days | 12 h (bulk 48 h) |

Rules of thumb:

* **`GLACIER_IR` is the sane default.** 5.75× cheaper than Standard, and a restore is
  a normal `GET` — no thaw, no waiting. If you are not sure, use this.
* **`DEEP_ARCHIVE` for the cold bulk** — old photos, finished video projects, anything
  you would only ever touch after losing the NAS. 4× cheaper again, at the price of a
  12–48 hour wait.
* **`STANDARD` for anything that changes weekly**, and for tiny files (see §3).

### The minimum-duration trap

Archive classes bill a minimum number of days *per object*, whether or not the object
still exists. Delete or overwrite a `DEEP_ARCHIVE` object after 3 days and you are
still billed for 180.

So a file that changes every week, stored in `DEEP_ARCHIVE`, is billed roughly 25 times
over — which makes it **more expensive than Standard**. Put working directories in
their own job on `GLACIER_IR` or `STANDARD`:

```sh
nasbak add-job archive   --source /shares/Photos    --class DEEP_ARCHIVE
nasbak add-job working   --source /shares/Documents --class STANDARD
```

`nasbak backup` warns when a run rewrites more than a tenth of a long-minimum set.

The same trap catches version retention. Noncurrent versions inherit the storage class
the object had when it was superseded, so expiring them after 30 days when they sit in
`DEEP_ARCHIVE` incurs a 150-day early-deletion charge on each one. `nasbak check` and
`config_validate` both flag `VERSION_RETENTION_DAYS` below the class minimum.

## 3. Small files cost more than they weigh

`STANDARD_IA` and `GLACIER_IR` bill a **minimum of 128 KiB per object**. `GLACIER` and
`DEEP_ARCHIVE` add **40 KiB of overhead per object** (32 KiB at the class rate, 8 KiB
at the Standard rate). A 4 KiB file is billed as if it were 128 KiB — or 44 KiB.

The crossover with Standard, solved exactly:

```
GLACIER_IR    128 KiB × $0.004  =  S × $0.023   →   S ≈ 22.3 KiB
DEEP_ARCHIVE  32 KiB × $0.00099 + 8 KiB × $0.023  =  S × $0.023 - S × $0.00099
                                                 →   S ≈  9.8 KiB
```

Below those sizes, `STANDARD` is genuinely cheaper. So `nasbak` runs the sync twice
over the same prefix with complementary size filters:

```
pass 1:  --min-size 24576B  --s3-storage-class GLACIER_IR
pass 2:  --max-size 24575B  --s3-storage-class STANDARD
```

Two details that matter:

* **The boundary is half-open** (`24576B` / `24575B`), so no file is claimed by both
  passes.
* **The large pass runs first.** rclone applies size filters to *both* sides of a sync,
  so once the large pass has written a file that grew past the threshold, the small
  pass no longer sees it on either side. Running small-first would delete the stale
  small object and re-upload it, spending a delete against the safety cap for nothing.

`nasbak estimate` reports the optimal threshold for your actual distribution — it
assigns every file to whichever tier is cheaper and tells you where the crossover
landed. How much this is worth depends entirely on your data: a share full of
documents and thumbnails saves a lot, a share full of video saves almost nothing.

Set `SMALL_FILE_CLASS` equal to `STORAGE_CLASS` to turn the whole mechanism off and
run a single pass.

## 4. Don't pay to ask "has this changed?"

This is the one that surprises people.

S3 does not store POSIX mtimes. rclone works around that by writing the original mtime
into object metadata — and metadata is **not** returned by `ListObjectsV2`. So rclone's
default comparison issues **one `HEAD` per object, per run**.

A `HEAD` is billed at the GET rate:

| Class | GET / 1,000 | 160,900 objects, weekly | Per year |
|---|---|---|---|
| STANDARD | $0.0004 | $0.064 | $3.35 |
| GLACIER_IR | $0.01 | $1.61 | **$83.67** |

$84/year to find out that nothing changed — on a backup whose *storage* costs $48/year.

`nasbak` defaults to `COMPARE_MODE=server-modtime`, which passes
`--use-server-modtime --update`:

* `--use-server-modtime` makes rclone use the `LastModified` already present in the
  `LIST` response. No `HEAD`.
* `--update` is not optional alongside it. The server modtime is the *upload* time,
  which for an unchanged file is always later than the local mtime; `--update` turns
  that into the rule you actually want — upload only when the local file is newer than
  the copy in S3. Without it, rclone resolves the mismatch by comparing hashes, which
  means re-reading every byte off the NAS disks every week.

The whole weekly comparison then costs one `LIST` page per 1,000 objects:
**$0.0008 per run** for 160,900 objects. Effectively free, at any scale.

### The trade-off, stated plainly

`--update` skips a file whose mtime moved *backwards* — restoring an old copy over a
newer one, or an application that resets timestamps. It is a narrow case, and
`nasbak verify --deep` catches it:

```sh
nasbak verify --deep      # compares MD5, costs nothing extra in S3
```

`--deep` compares the local MD5 against the object's ETag, which comes free in the
`LIST` response. It does re-read the NAS disks, so run it monthly rather than weekly.
(Objects uploaded in multiple parts — over 200 MiB by default — have a composite ETag
rather than an MD5, so rclone reads their checksum from metadata with a `HEAD`. For a
few thousand large files that is cents, not dollars.)

The other modes:

| `COMPARE_MODE` | Requests per run | Catches | Notes |
|---|---|---|---|
| `server-modtime` | LIST only | mtime changes | **default** |
| `size-only` | LIST only | size changes | cheapest; misses same-size edits |
| `checksum` | LIST only | everything | re-reads all local data |
| `modtime` | 1 HEAD/object | mtime changes | rclone stock. See the table above. |

## 5. Upload straight into the target class

You can reach an archive class two ways: `PUT` directly with
`x-amz-storage-class: GLACIER_IR`, or `PUT` into Standard and let a lifecycle rule
transition it. Direct `PUT` wins on every axis:

| | Direct PUT | Lifecycle transition |
|---|---|---|
| Transition requests | none | $0.01 per 1,000 objects |
| Time at Standard prices | none | until the rule fires |
| Objects < 128 KiB | your choice of class | never transitioned at all |

For 160,900 objects that is $1.61 of transition charges avoided, plus however many
days of Standard pricing. `nasbak` therefore ships **no transition rules** — rclone
sets the storage class on upload.

## 6. The lifecycle rules that are actually load-bearing

`nasbak bootstrap` writes four:

1. **`AbortIncompleteMultipartUpload` after 7 days.** The classic silent leak. An
   interrupted upload of a 4 GB video leaves its parts in the bucket; they are billed
   as storage, they do not appear in the console object listing, and they are not
   counted by `aws s3 ls --summarize` or `rclone size`. Nothing else cleans them up.
   `nasbak prune` clears them on demand.
2. **`NoncurrentVersionExpiration` after `VERSION_RETENTION_DAYS`.** The undo window.
   `NewerNoncurrentVersions` keeps a floor of recent versions regardless.
3. **`ExpiredObjectDeleteMarker`.** Deleting a file in a versioned bucket leaves a
   delete marker. Markers are free to store but they are returned by `LIST`, and you
   pay to list them on every weekly run.
4. **Run reports expire after 400 days.**

## 7. Encryption: SSE-S3, not SSE-KMS

SSE-S3 (`AES256`) is free. SSE-KMS charges per request — $0.03 per 10,000 — plus $1/month
per key. On a first seed of 160,900 objects that is about $0.48, and every restore pays
it again. It buys you key rotation policy and CloudTrail records of decryption, which
is not usually what a home NAS backup needs. `SSE=AES256` is the default; set
`SSE=aws:kms` if you have a reason.

If you want the NAS to hold the keys, use rclone's `crypt` remote instead — but note
that it obscures filenames, which makes partial restores and this cost analysis harder.

## 8. Restores are the expensive direction

| Class | Retrieval/GB | + egress/GB | 1 TB back to the NAS |
|---|---|---|---|
| STANDARD | — | $0.09 | $83 |
| GLACIER_IR | $0.03 | $0.09 | $114 |
| GLACIER (bulk) | free | $0.09 | $83 |
| DEEP_ARCHIVE (bulk) | $0.0025 | $0.09 | $86 |
| DEEP_ARCHIVE (standard) | $0.02 | $0.09 | $104 |

The first 100 GB of egress each month is free, which covers most partial restores.

Two things worth knowing before you ever need them:

* **Bulk retrieval is much cheaper and usually fine.** For `DEEP_ARCHIVE`, bulk is
  $0.0025/GB against $0.02/GB for standard — 8× — for a 48-hour wait instead of 12.
  If the NAS has just died you are waiting for hardware anyway. `nasbak thaw` defaults
  to bulk.
* **Restoring to EC2 in the same region is free.** For a full 1 TB recovery, spinning
  up an instance, restoring there, and shipping the disk (or re-syncing selectively)
  can beat $83 of egress. For anything smaller, don't bother.

## 9. Set a budget alarm

The CloudFormation template takes `NotificationEmail` and creates a monthly S3 budget
that emails you at 80% of actual and 100% of forecast. Do this before the first seed.
A misconfiguration — `COMPARE_MODE=modtime` on `GLACIER_IR`, a job pointed at a
directory of constantly-rewritten temp files — should reach your inbox, not next
month's card statement.

## Summary

| Decision | Default | Saves |
|---|---|---|
| Mirror, not repeated full copies | `rclone sync` | ~85% in year 1, more every year after |
| Archive storage class | `GLACIER_IR` | 83% vs Standard |
| Small files to `STANDARD` | under 24 KiB | 0–60%, entirely down to your file mix |
| LIST-only comparison | `server-modtime` | ~$84/yr at 160k objects |
| Direct PUT, no transitions | always | $0.01/1,000 objects |
| Abort incomplete uploads | 7 days | unbounded |
| SSE-S3 over SSE-KMS | `AES256` | ~$0.48/seed + $1/mo |
| Bulk thaw on restore | `--priority Bulk` | 8× on retrieval |
