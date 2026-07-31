# Event-driven ingestion: S3 → EventBridge → EMR Serverless

**In one line:** don't poll a bucket on a timer and don't keep a cluster idling —
let the file's arrival *itself* start the job.

This folder has two parts:
- a **runnable local proof** (no AWS account) that shows why reacting to a file
  event beats checking for it on a schedule;
- the **real AWS wiring** (`aws/`) from an AWS/Snowflake portfolio build:
  S3 → EventBridge → Step Functions → EMR Serverless.

---

## The problem

You want to process each file as it lands in S3. Two common ways to notice it, both
wasteful:

- **Poll on a schedule.** A cron job lists the prefix every N minutes. You pay for
  every wake-up whether or not anything arrived, and a file can sit for up to a full
  interval before you touch it.
- **Keep a cluster warm.** So you're "ready", a cluster runs between batches — paying
  by the hour to mostly wait.

Polling adds latency and idle cost; a warm cluster adds idle cost. At small scale you
don't notice. On a real pipeline you pay for it twice.

## The fix: let the arrival trigger the work

Flip it around. The moment a file lands, S3 emits an event, and that event starts the
job. Nothing polls; nothing idles.

```
file lands in S3 ─▶ EventBridge rule ─▶ Step Functions ─▶ EMR Serverless (PySpark)
  (EventBridge on)   (Object Created)     (startJobRun)      (spins up on demand)
```

- **S3 → EventBridge**: one toggle on the bucket makes every object event a
  first-class EventBridge event.
- **EventBridge rule**: matches `Object Created` for your bucket/prefix and starts a
  Step Functions execution.
- **Step Functions**: calls EMR Serverless `startJobRun`, passing the new file's
  `s3://` path (built from the event's bucket + key).
- **EMR Serverless**: provisions workers for that one job and releases them when it's
  done — no cluster sitting idle between files.

## Run the local proof

```bash
bash run.sh
```

No AWS needed. It uses the Linux kernel's **inotify** — the same *push* idea as
S3 → EventBridge — to contrast the two approaches. Prerequisite on WSL Ubuntu 24.04:

```bash
sudo apt update && sudo apt install -y python3 python3-venv
```

**Platform note:** `inotify` is Linux-only, so the event-driven half runs on Linux or
**WSL2**, not on macOS or native Windows. On WSL, run it from the **Linux filesystem**
(your WSL home) — inotify events don't fire reliably on Windows-mounted `/mnt/c/…`
paths. (The polling half works anywhere Python does; only the inotify half is
Linux-specific.)

Captured output is in [`output/output.txt`](output/output.txt). What you'll see:

```
POLLING       poll 1: empty … poll 2: empty … poll 3: empty … poll 4: found it
              => 3 idle checks before it was noticed
EVENT-DRIVEN  watching … event received: sample_listing.json created
              => 0 idle checks. Woke the instant the file landed.
```

Polling burns three checks on a timer and notices the file up to a full interval
late. The event-driven watch sits at **zero** CPU and fires the moment the file
lands. That's the whole idea, shrunk to one machine.

## The AWS build (`aws/`)

The real thing, as **one CloudFormation stack** plus a deploy script. It runs on your
account, not here.

- **[`aws/event-driven-ingestion.cfn.yaml`](aws/event-driven-ingestion.cfn.yaml)** —
  the whole stack: the S3 bucket (EventBridge switched on), the three IAM roles, the
  EMR Serverless application, the Step Functions state machine (one `.sync` task that
  runs the PySpark job), and the EventBridge rule that matches `Object Created` under
  `incoming/`. The new file's path is built from the event via
  `States.Format('s3://{}/{}', $.detail.bucket.name, $.detail.object.key)`.
- **[`aws/deploy.sh`](aws/deploy.sh)** — deploys the stack and uploads the job.
- **[`aws/emr_serverless_job.py`](aws/emr_serverless_job.py)** — the PySpark job:
  read the one new file, cast + timestamp, append to `curated/`. Its Spark logic is
  exercised in this repo's local test; only the `s3://` I/O needs AWS.

### Deploy it — one command

**Prerequisites:** AWS CLI v2, configured (`aws configure`) with permission to create
CloudFormation stacks, IAM roles, S3, EventBridge, Step Functions and EMR Serverless.

**Set your region:** edit `REGION` at the top of `aws/deploy.sh` (or `export
AWS_REGION=...`). Optional: change the EMR `ReleaseLabel` (default `emr-7.2.0`) if your
region doesn't offer it — it's a parameter in the template.

```bash
bash aws/deploy.sh                 # or: bash aws/deploy.sh my-stack-name
```

That creates every resource, then uploads the job. When it finishes it prints the
bucket name. Then just drop a file:

```bash
aws s3 cp path/to/listing.json s3://<bucket-it-printed>/incoming/
```

EventBridge matches it, Step Functions starts, and EMR Serverless runs the job — no
cron, no idle cluster. Watch the run in the **Step Functions console** (state machine
`carsales-ingest`); output lands in `s3://<bucket>/curated/listings/`.

**Tear it down:** empty the bucket, then
`aws cloudformation delete-stack --stack-name carsales-event-ingest`.

**Honest scope:** the template is validated with `cfn-lint`. Initial deployment during 
my testing had surfaced a missing IAM permission — the Step Functions role needs `events:PutRule`/`PutTargets`/`DescribeRule` because the `.sync`
pattern creates a managed EventBridge rule to catch job completion; that's now in the
template. Other `.sync` pieces people miss — `GetJobRun`, `CancelJobRun`, `iam:PassRole`
— are included too. The EMR service-linked role `AWSServiceRoleForAmazonEMRServerless`
is created automatically when the stack creates the application (your credentials need
`iam:CreateServiceLinkedRole`, which most do).

**Re-deploying after a failed stack:** CloudFormation can't deploy over a stack stuck
in `ROLLBACK_COMPLETE`/`CREATE_FAILED` — delete it first, then run `deploy.sh` again:
`aws cloudformation delete-stack --stack-name carsales-event-ingest`.

## Files

```
event-driven-ingestion-aws/
├── event-driven-ingestion-aws-README.md   this file
├── run.sh                     bash run.sh → the local, no-account proof
├── local_event_vs_poll.py     polling vs event-driven, via inotify
├── requirements.txt           Python dependency (inotify_simple)
├── config/
│   └── sample_listing.json    the file that "lands" in the proof
├── output/
│   └── output.txt             captured proof output
└── aws/                       the real AWS build (one CloudFormation stack)
    ├── event-driven-ingestion.cfn.yaml   the whole stack (bucket, roles, EMR app,
    │                                      state machine, EventBridge rule)
    ├── deploy.sh              deploy the stack + upload the job
    └── emr_serverless_job.py  the PySpark job
```

---

*The local proof and the PySpark transform were run on PySpark 4.2 / Java 21. The
CloudFormation template is validated with `cfn-lint`, deployed using real AWS account 
and had test run it successfully end-end*
