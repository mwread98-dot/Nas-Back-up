# Getting your data back

A backup you have never restored from is a hypothesis. Do the drill in §1 now, while
nothing is wrong.

---

## 1. The drill (do this today, it costs pennies)

```sh
nasbak restore --job photos --to /tmp/restore-test --path 2019/italy
diff -r /mnt/HD/HD_a2/Photos/2019/italy /tmp/restore-test/
rm -rf /tmp/restore-test
```

A few hundred MB is inside the free 100 GB/month egress allowance. If this works, your
backup works.

Put a reminder in your calendar to repeat it every six months.

## 2. Get one file back

```sh
nasbak restore --job photos --to /tmp/recovered --path 2019/italy/DSC_0042.jpg
```

`--path` is relative to the backup set's source directory.

## 3. Get an earlier version of a file

Every change inside the retention window is recoverable.

```sh
# What versions exist?
nasbak versions --job documents --path tax/2024-return.ods

# Take the bucket as it was on a date, and pull that one file
nasbak restore --job documents --to /tmp/recovered \
    --path tax/2024-return.ods --at 2025-08-01
```

`--at` accepts `2025-08-01` or a full `2025-08-01T14:30:00Z`.

## 4. Undo an accidental deletion

You deleted a folder on the NAS. The next weekly run mirrored that deletion, so the
objects are now *noncurrent versions* behind delete markers — still there, still
recoverable, until `VERSION_RETENTION_DAYS` expires them.

```sh
# Read the bucket as it was before the sync that removed them
nasbak restore --job photos --to /mnt/HD/HD_a2/Photos --path 2019/italy \
    --at 2025-08-30T00:00:00Z
```

Pick a timestamp you are sure predates the deletion. Restoring into the live share puts
the files straight back where they were; the following weekly run then re-uploads them
as current objects.

**This is why `VERSION_RETENTION_DAYS` matters.** At the default 90 days you have three
months to notice. If you would rather have longer, raise it — only *changed* files
consume it, so on a stable NAS the extra cost is close to nothing.

## 5. Recover from ransomware

The scenario: something encrypts the NAS shares in place. The next weekly run
faithfully mirrors the encrypted files to S3.

What protects you:

* **`MAX_DELETE_PCT`.** Mass encryption usually renames files, which looks like mass
  deletion. The run aborts instead.
* **The IAM policy.** The NAS's key is explicitly denied `s3:DeleteObjectVersion` and
  `s3:PutBucketVersioning`. Even a fully compromised NAS can only write *new* versions —
  the originals cannot be purged.
* **`--at`.** Restore the entire bucket as it was before the attack.

```sh
# 1. Get the NAS clean first, and stop the schedule so it cannot re-mirror
nasbak cron remove

# 2. Restore everything to a fresh location, as of a known-good date
nasbak restore --job photos --to /mnt/HD/HD_a2/Photos-recovered \
    --at 2025-08-15T00:00:00Z

# 3. Verify, swap it in, and re-enable
nasbak cron install
```

The limit is the retention window. If you want a guarantee that even an AWS root
credential compromise cannot erase the backup, add S3 Object Lock in compliance mode
for a fixed period — that is genuinely immutable, and genuinely irreversible, so read
the AWS docs carefully before enabling it.

## 6. The NAS is dead — restore everything

### If the data is in `STANDARD`, `STANDARD_IA` or `GLACIER_IR`

No thaw needed.

```sh
nasbak restore --job photos --to /mnt/HD/HD_a2/Photos
```

### If the data is in `GLACIER` or `DEEP_ARCHIVE`

Objects must be thawed first.

```sh
nasbak thaw --job photos                     # bulk: cheapest, 48 h for DEEP_ARCHIVE
nasbak thaw --job photos --priority Standard # 12 h, 8x the retrieval cost

nasbak thaw --job photos --status            # poll until it reports done

nasbak restore --job photos --to /mnt/HD/HD_a2/Photos
```

Thawed copies stay readable for `--days` (default 7). Download inside that window or
pay to thaw again.

**Take the bulk tier.** For `DEEP_ARCHIVE`, bulk is $0.0025/GB against $0.02/GB for
standard. On 1 TB that is $2.56 versus $20.48, for a 48-hour wait instead of 12. If the
NAS has just died you are waiting on replacement hardware anyway.

### Cost of a full 1 TB recovery

| | Retrieval | Egress | Total |
|---|---|---|---|
| GLACIER_IR | $30.72 | $83.16 | $113.88 |
| DEEP_ARCHIVE, bulk | $2.56 | $83.16 | $85.72 |
| DEEP_ARCHIVE, standard | $20.48 | $83.16 | $103.64 |

Egress dominates, and it is the same whatever class you chose — which is worth
remembering when picking one. The first 100 GB each month is free.

For a full multi-terabyte recovery, restoring to an EC2 instance in the same region
costs **no egress at all**. Restore there, then bring the data home over however many
months suits you, or use AWS Snowball. Below a terabyte or so it is not worth the
complexity.

## 7. Restore without nasbak

If the NAS is gone and you just want your files from any machine, you only need rclone
and the credentials. Nothing about the bucket layout is proprietary — objects are
stored under their original paths with their original names.

```sh
rclone config create s3backup s3 provider AWS \
    access_key_id AKIA... secret_access_key ... region eu-west-2

rclone ls   s3backup:your-bucket/photos
rclone copy s3backup:your-bucket/photos /somewhere/local -P
```

Or just use the AWS console and click download. Keep a copy of your bucket name,
region and access key somewhere that is not the NAS — a password manager is ideal.

## 8. Check a restore actually matched

```sh
nasbak verify --job photos --deep
```

Compares MD5 checksums between the NAS and S3. It re-reads the local files but costs
nothing extra in S3, because the checksums come from the `LIST` response.
