# CDC on AWS: PostgreSQL → Debezium on MSK Connect → MSK → ClickHouse

A runnable demo, fully in Terraform, that streams every insert, update and delete
from an RDS for PostgreSQL table into ClickHouse — and then shows how a stalled
replication slot can take down the source database.

```
RDS PostgreSQL 17          MSK Connect                 Amazon MSK              EC2
public.transactions  ──►   Debezium PG connector  ──►  cdc.public.transactions ──►  ClickHouse
(WAL, pgoutput,            (1 task, reads the slot)     (3 partitions)              Kafka engine
 debezium_slot)                                                                     → MV
                                                                                    → ReplacingMergeTree
```

## What gets created

| Piece | Details |
|---|---|
| Network | VPC, public + private subnets in 2 (or 3) AZs, one NAT gateway, S3 gateway endpoint |
| Source | RDS for PostgreSQL 17 (`db.t4g.micro`, 20 GB), `rds.logical_replication = 1`, no storage autoscaling |
| Kafka | MSK provisioned, `kafka.t3.small`, one broker per AZ, plaintext inside the VPC |
| Connector | MSK Connect 3.7.x (Java 17) running Debezium 3.x, `ExtractNewRecordState` SMT, heartbeat |
| Sink | ClickHouse on an EC2 box (`t3.large`, Amazon Linux 2023), reached through SSM, also the psql client |
| Alarms | CloudWatch alarms on `OldestReplicationSlotLag` and `FreeStorageSpace` |

35 resources in total. No secrets in the repo: both database passwords are generated
by `random_password` at apply time.

> **This costs real money.** MSK brokers, the MSK Connect MCU, RDS, the NAT gateway
> and the EC2 box all bill by the hour, roughly $5-8/day in `eu-west-1` at the time of
> writing. Run `make destroy` when you are done — see [Clean up](#clean-up).

---

## 1. Install the prerequisites

macOS with Homebrew:

```bash
brew install awscli gh
```

Terraform is **not** in homebrew-core (HashiCorp's license change removed it), so take it
from HashiCorp's own tap — the demo needs 1.6 or newer:

```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
```

Optional, only needed for `make shell` (an interactive shell on the ClickHouse box). It
installs a `.pkg` through `sudo`, so it will ask for your password:

```bash
brew install --cask session-manager-plugin
```

Everything else the demo uses — `curl`, `zip`, `make` — ships with macOS. On Linux, install
`awscli`, `terraform`, `curl` and `zip` with your package manager.

Verify:

```bash
terraform version && aws --version
```

## 2. Sign in to AWS

With AWS CLI 2.32 or newer, this gives you short-term credentials that rotate
automatically and expire within 12 hours:

```bash
aws login
```

Older CLI, or you prefer long-term access keys:

```bash
aws configure
```

Either way, confirm you are pointed at the account you intend before spending anything:

```bash
aws sts get-caller-identity
```

You need permission to create VPC, EC2, RDS, MSK, MSK Connect, S3, IAM, CloudWatch and
SNS resources. An administrator-equivalent policy is the simple answer for a demo account.

## 3. Pick your region

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Then edit it:

```hcl
region   = "eu-west-1"
az_count = 2             # 3 for a production-like Kafka setup
# alarm_email = "you@example.com"   # uncomment to get the alarms by email
```

**The region in `terraform.tfvars` wins** — the Terraform provider reads `var.region`, so it
ignores whatever your AWS CLI default is. Set them to the same value unless you enjoy
staring at an empty console. Every `make` target picks the region up from
`terraform output`, so they all follow this file.

Set `alarm_email` if you want the CloudWatch alarms to actually reach you; leave it empty
and no SNS topic is created, so the alarms only show up in the console.

## 4. Build it

```bash
make infra       # ~30 min, MSK is the slow part
make init        # table, debezium user, publication, ClickHouse tables, 10k rows
make connector   # starts Debezium: snapshot first, then streaming
make compare     # same row count and total on both sides
```

That is the whole setup. `make infra` also downloads Debezium and repackages it as the ZIP
that MSK Connect wants (`make plugin` on its own, if you want just that).

The connector is a separate step on purpose: the table, the `debezium` user and the
publication have to exist before Debezium starts, otherwise the connector fails its first
snapshot.

Nothing to copy by hand between steps — `scripts/box.sh` runs SQL on the ClickHouse box
through SSM `send-command`, reading the endpoints straight out of the Terraform outputs.

---

## The demo

### 1. Snapshot, then live changes

```bash
make compare           # 10,000 rows on both sides, all with _op = 'r' (snapshot)
make churn N=2000      # settle, refund and delete
make compare           # totals match again a few seconds later
make latency           # p50 / p99 lag from commit to ClickHouse
make top-merchants     # the reason the data is in ClickHouse in the first place
```

### 2. Break it: a slot with no reader

```bash
make slot              # retained_wal is small, active = t
make stop-connector    # deletes the connector. The slot does NOT go away.
make flood N=1000000   # 1M inserts + an update of every row
make slot              # active = f, retained_wal keeps growing
```

Watch `FreeStorageSpace` drop and the `replication-slot-lag` alarm fire in CloudWatch.
Keep flooding and the database eventually runs out of disk, even though nothing at all is
wrong with the database itself. This is the failure mode worth remembering: an abandoned
replication slot is a slow disk-space leak on your source of truth.

### 3. Recover

```bash
make start-connector   # resumes from the stored offset, no new snapshot
make slot              # retained_wal shrinks once Debezium catches up
make compare
```

Recovery works without a re-snapshot because the worker config pins
`offset.storage.topic`. Without it, every new MSK Connect connector gets a fresh offset
topic and starts over from scratch.

Last resort, when the disk is about to fill: `make drop-slot`. WAL is freed immediately,
but the CDC position is gone and the connector needs a new snapshot.

---

## All make targets

| Target | What it does |
|---|---|
| `make plugin` | Download Debezium, repackage as a ZIP for MSK Connect |
| `make infra` | Everything except the connector, ~30 min |
| `make init` | Table, `debezium` user, publication, ClickHouse objects, 10k rows |
| `make connector` | Create the Debezium connector, ~5-10 min |
| `make up` | `infra` + `init` + `connector` in one go |
| `make seed N=50000` | Insert N more rows |
| `make churn N=5000` | Settle, refund and delete, to generate updates and deletes |
| `make flood N=1000000` | Heavy write load, for the stalled-slot demo |
| `make compare` | PostgreSQL vs ClickHouse row counts and totals |
| `make latency` | p50 / p99 end-to-end lag |
| `make top-merchants` | The analytical query ClickHouse is there for |
| `make slot` | WAL retained by the replication slot |
| `make stop-connector` | Delete the connector, leave the slot behind |
| `make start-connector` | Recreate it, resumes from the stored offset |
| `make drop-slot` | Emergency brake: frees WAL, loses the CDC position |
| `make logs` | Tail the MSK Connect worker logs |
| `make shell` | Interactive shell on the ClickHouse box (needs session-manager-plugin) |
| `make destroy` | Tear it all down |

## Clean up

```bash
make destroy
```

Check the AWS console afterwards and confirm the MSK cluster, the RDS instance, the NAT
gateway and the EC2 box are really gone. Those four are the ones that cost you money if a
destroy half-fails.

## Troubleshooting

**`brew install terraform` says no such formula.** Expected — use the HashiCorp tap as in
step 1.

**`make shell` fails but everything else works.** You are missing
`session-manager-plugin`. Nothing else needs it; `scripts/box.sh` uses SSM
`send-command`, not `start-session`.

**The connector goes to `FAILED` on its first run.** Almost always `make init` was skipped
or did not finish, so the publication and the `debezium` role do not exist yet. Check with
`make logs`, then run `make init` and `make connector` again.

**Resources appear in the wrong region.** `terraform.tfvars` wins over your AWS CLI
default. See step 3.

**`make compare` shows a mismatch.** Give it a few seconds — it is asynchronous
replication, not a transaction. If it persists, `make logs` will tell you whether the
connector is still running.

## Demo shortcuts you should not copy to production

- Plaintext Kafka with no auth. Use IAM auth + TLS on MSK, MSK Connect and ClickHouse.
- The Debezium password sits in the connector config and in Terraform state. Use an MSK
  Connect config provider backed by Secrets Manager.
- One shared security group for everything. Split it per component.
- A single-AZ RDS instance with no backups worth the name.
- ClickHouse on one EC2 box with local storage, no replication.
