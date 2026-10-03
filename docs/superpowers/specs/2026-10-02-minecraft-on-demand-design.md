# On-demand family Minecraft server — design

Date: 2026-10-02
Status: Draft, awaiting review

## 1. Goal

A Minecraft server for a family that:

- costs money only while it is being played on;
- starts by itself when someone connects to `minecraft.dosaki.net` (the DNS lookup is the trigger);
- checks the player count every 30 minutes and, when nobody is online, backs up the world and stops the instance;
- has a web map at `https://map.minecraft.dosaki.net` that you can view even while the server is off;
- keeps grandfather/father/son (GFS) world backups in S3;
- redeploys automatically when a PR is merged to `main`, warning players and stopping the server first.

### Success criteria

- Joining from a stopped state works in two steps: click Join (it fails), wait ~90 s, click Join again.
- The instance stops itself 30–60 minutes after the last player leaves.
- Viewing the map never starts the instance.
- While stopped, AWS costs are only storage, DNS and backups (about $3–4/month); while running, about $0.18/hour.
- No player usernames, emails, AWS keys or account IDs are committed to the (public) repository.

### Fixed decisions

| Decision | Choice |
|---|---|
| Cloud / account | AWS, CLI profile `dosaki` (personal account), never the default profile |
| Region | Server, backups and map in `eu-west-1`; DNS-query logging and the waker in `us-east-1` (required by Route 53) |
| Server software | Paper (Java Edition), plugins only, no client mods |
| World | Fresh |
| Instance | EC2 `m7g.xlarge` (4 vCPU / 16 GB, Graviton), Amazon Linux 2023 arm64, stopped ⇄ running |
| Disk | 30 GB gp3 root volume, kept while the instance is stopped |
| Plugins | OneLife (gravestones) and CraftEngine; CraftEngine self-hosts the required resource pack on the game port (25565) |
| Map | squaremap, static tiles in S3 behind CloudFront |
| Backups | S3 only (no EBS snapshots), GFS |
| IaC | Terraform, state in S3 with native lockfile |
| CI/CD | GitHub Actions, public repo `dosaki/minecraft-server`, AWS access via OIDC |

## 2. Architecture

```
 Player PC ── DNS lookup ──► Route 53 zone "minecraft.dosaki.net"  (query logging)
                                   │
                                   ▼
                     CloudWatch Logs  (us-east-1)
                                   │ subscription filter (all events)
                                   ▼
                     Lambda mc-waker  (us-east-1)
                        │ reads SSM /minecraft/maintenance
                        │ ec2:StartInstances (eu-west-1)
                        ▼
                     EC2 m7g.xlarge  (eu-west-1, default VPC, public subnet)
                        │ boot: pull config from S3, UPSERT A record, start Paper
                        │ timers: idle-check 30 min, backup 60 min, map-sync 10 min
                        ├──► S3 dosaki-minecraft-backups  (GFS + config/ prefix)
                        └──► S3 dosaki-minecraft-map ──► CloudFront ──► map.minecraft.dosaki.net
```

## 3. DNS and the wake-up path

### Zone

- New public hosted zone `minecraft.dosaki.net`, delegated from the existing `dosaki.net` zone through an NS record. No other records in `dosaki.net` change.
- Records in the child zone:
  - `minecraft.dosaki.net` A, TTL 30 s. The instance overwrites it on every boot. Terraform creates it with a placeholder and uses `ignore_changes` on its value.
  - `map.minecraft.dosaki.net` A/AAAA alias to the CloudFront distribution.
  - ACM DNS-validation CNAME(s).
- Query logging is enabled on this zone only. It writes to log group `/aws/route53/minecraft.dosaki.net` in `us-east-1`, which has a resource policy allowing `route53.amazonaws.com` to write. Retention is 3 days.

### Waker Lambda (`mc-waker`, Python 3.13, us-east-1)

- Triggered by a CloudWatch Logs subscription filter with an empty pattern, so every query event in the zone reaches it. Traffic is family-scale, so this is cheap.
- For each log event:
  1. Parse the query name (4th space-separated field of the Route 53 query-log format: `version timestamp zone_id query_name query_type rcode protocol edge resolver_ip edns`), lowercase it and strip any trailing dot.
  2. Wake only if the name is exactly `minecraft.dosaki.net` or `_minecraft._tcp.minecraft.dosaki.net`. Every other name, including `map.minecraft.dosaki.net`, is ignored.
- Wake procedure:
  1. Read SSM parameter `/minecraft/maintenance` in eu-west-1. If it is `true`, log and do nothing.
  2. `DescribeInstances` on the configured instance ID.
  3. If the state is `stopped`, call `StartInstances`. If it is `pending`, `running`, `stopping` or `shutting-down`, do nothing: a later lookup starts a stopping instance once it has fully stopped.
- Running the handler several times is harmless. A `StartInstances` race that fails with `IncorrectInstanceState` is logged and swallowed.
- IAM: `ec2:DescribeInstances`, `ec2:StartInstances` limited to the instance ARN, `ssm:GetParameter` on the maintenance parameter, and basic logging permissions.

### Boot DNS update (`mc-update-dns.sh`)

- Runs as a oneshot systemd unit after the network is up and before `minecraft.service`.
- Reads the instance's public IPv4 from IMDSv2 and UPSERTs the A record (TTL 30 s) in the child zone.
- The instance role may call `route53:ChangeResourceRecordSets` only on the child zone.

## 4. The server instance

### Base

- Amazon Linux 2023 arm64 AMI, chosen at creation time; Terraform ignores later AMI changes so the instance is never replaced by accident.
- Runs in the default VPC with a public IP assigned at launch. No Elastic IP (it would cost money while stopped).
- `instance_initiated_shutdown_behavior = "stop"`. IMDSv2 required.
- Security group: inbound `25565/tcp` from `0.0.0.0/0` and `::/0` only. No SSH. Shell access goes through SSM Session Manager (the instance profile includes `AmazonSSMManagedInstanceCore`).
- Java: Amazon Corretto, whichever major version the pinned Paper build requires.
- Server directory: `/srv/minecraft`, owned by user `minecraft`.

### Configuration delivery (pull on every boot)

- Terraform uploads the repo's `server/` directory (scripts, systemd units, config templates) to `s3://dosaki-minecraft-backups/config/` as `aws_s3_object` resources. A change to any file therefore shows up in `terraform plan`.
- `user_data` (first boot only) installs a single `mc-bootstrap.service` that runs on every boot. It:
  1. syncs `config/` from S3 into `/opt/minecraft`;
  2. installs or refreshes the systemd units and scripts;
  3. downloads the pinned Paper jar and plugin jars if their checksums differ;
  4. renders `server.properties` and the plugin configs;
  5. reads `/minecraft/players` (SecureString) and writes `whitelist.json` and `ops.json`;
  6. runs `mc-update-dns`, then starts `minecraft.service` and the timers.
- The Paper version, Paper build and plugin versions (with checksums) are pinned in a Terraform-managed manifest uploaded with `config/`.

### Players and whitelist

- SSM SecureString `/minecraft/players` holds JSON: `{"ops": ["Name"], "whitelist": ["Name", ...]}`.
- It lives outside Terraform: it never appears in the repo, in state or in plan output. `scripts/set-players.sh` (no data inside it) wraps `aws ssm put-parameter --profile dosaki --type SecureString --overwrite`.
- The parameter is the single source of truth. Boot overwrites `whitelist.json` and `ops.json`, so in-game `/whitelist` edits don't survive a reboot.
- `server.properties`: `white-list=true`, `enforce-whitelist=true`, `enable-rcon=true`, `rcon.port=25575`. Vanilla RCON listens on all interfaces, but the security group never opens it, so it can only be reached from the instance itself.
- The RCON password is a random string generated by Terraform (`random_password`), stored in SSM `/minecraft/rcon-password` (SecureString), and read at boot.

### `minecraft.service`

- `ExecStart`: `java -Xms12G -Xmx12G <Aikar flags> -jar paper.jar --nogui`, which leaves ~4 GB for the OS, the AWS CLI and the map sync.
- `ExecStop`: RCON `stop`, then wait for the process to exit. `TimeoutStopSec=120`.
- `Restart=on-failure`.

## 5. Idle shutdown

- `mc-idle-check.timer`: `OnBootSec=30min`, `OnUnitActiveSec=30min`.
- `mc-idle-check.sh`:
  1. Send RCON `list` and parse the online count.
  2. If the count is greater than 0, exit.
  3. If the count is 0, **or** RCON fails, **or** `minecraft.service` isn't active: run `mc-shutdown`.
- `mc-shutdown.sh` (shared with deploys):
  1. Run `mc-backup`. If it fails, log the error and carry on.
  2. Run `mc-map-sync`. If it fails, log the error and carry on.
  3. `systemctl poweroff`. `minecraft.service` stops cleanly, then the instance stops.
- AFK players count as online. Budget alerts (section 9) cover runaway spend.

## 6. Backups (GFS in S3)

### Bucket `dosaki-minecraft-backups` (eu-west-1)

- Block Public Access on, SSE-S3, versioning off.
- Write access: the instance role may write to `son/`, `father/`, `grandfather/` and `latest/` and read `config/`. The `minecraft-deploy` role writes `config/`.
- The `config/` prefix is used for configuration delivery (section 4) and is excluded from lifecycle rules.

### Archive contents

- The contents of `/srv/minecraft`, minus `logs/`, `cache/`, `libraries/`, `versions/`, the Paper jar, squaremap's `web/` and tile output, and CraftEngine's `libs/` and `generated/`.
- That covers the world folders, plugin data and configs, and server properties.
- Format: `tar` + `zstd`, built in `/var/tmp`, then uploaded.

### Consistency

RCON `save-off` → `save-all flush` → archive → `save-on`. A shell `trap` guarantees `save-on` runs. If RCON is unreachable (Paper is down), the files are archived as they are.

### Keys and retention

All dates and ISO weeks are in UTC.

| Key | Written when | Lifecycle |
|---|---|---|
| `son/YYYY-MM-DD.tar.zst` | every backup; **overwrites** the same day's object, so there is at most one per day | expires after 14 days |
| `father/YYYY-Www.tar.zst` | only if no `father/YYYY-Www*` exists yet; never overwritten | expires after 56 days |
| `grandfather/YYYY-MM.tar.zst` | only if no `grandfather/YYYY-MM*` exists yet; never overwritten | expires after 365 days |
| `latest/world.tar.zst` | every backup; overwritten | never expires |

- The archive is uploaded once, to `son/`. The `father/`, `grandfather/` and `latest/` keys are filled by server-side `CopyObject`.
- A lifecycle rule aborts incomplete multipart uploads after 1 day.
- The classification ("which keys does this backup write?") is a pure function `(utc_now, existing_father_keys, existing_grandfather_keys) → [keys]` so it can be unit-tested.

### Schedule

- `mc-backup.timer`: hourly while the server is running (`OnBootSec=60min`, `OnUnitActiveSec=60min`).
- Also during every `mc-shutdown` (idle shutdown and deploys).
- Stopping the instance from the console outside these paths still stops Paper cleanly but takes no new backup. The world on disk is safe; the newest backup may be up to an hour old.

### Restore

`mc-restore.sh <s3-key>`:

1. Stop `minecraft.service`.
2. Move the current world directories to `/srv/minecraft/restore-backup-<timestamp>/`.
3. Download and extract the archive.
4. Start `minecraft.service`.

Old world copies are never deleted automatically.

## 7. Web map

- Plugin: squaremap. Its web output directory syncs to S3 bucket `dosaki-minecraft-map` (eu-west-1, private).
- `mc-map-sync.timer` runs every 10 minutes while the server is up; `mc-shutdown` also runs a final sync. The command is `aws s3 sync <squaremap web dir> s3://dosaki-minecraft-map/ --delete`.
- CloudFront distribution:
  - Origin Access Control to the bucket; the bucket policy allows only this distribution.
  - Default root object `index.html`.
  - Alias `map.minecraft.dosaki.net`, with an ACM certificate in us-east-1 (DNS-validated in the child zone).
  - HTTPS only, redirecting HTTP to HTTPS. `PriceClass_100`.
- The map is static: terrain only, no live player markers. Viewing it never involves the instance.

## 8. Repository layout

```
bootstrap/            # one-time: state bucket, GitHub OIDC provider, deploy + plan roles
terraform/            # main stack
  providers.tf  variables.tf  outputs.tf  backend.tf
  dns.tf  waker.tf  server.tf  backups.tf  map.tf  budget.tf  config_upload.tf
lambda/waker/         # handler.py, tests/
server/
  bin/       mc-bootstrap.sh mc-update-dns.sh mc-idle-check.sh mc-shutdown.sh
             mc-backup.sh mc-map-sync.sh mc-restore.sh mc-rcon (small RCON client)
  lib/       gfs.py (backup classification) + tests/
  systemd/   minecraft.service mc-bootstrap.service mc-*.timer mc-*.service
  config/    server.properties.tmpl, paper/squaremap config, versions manifest
scripts/      set-players.sh
.github/workflows/  ci.yml  deploy.yml
docs/superpowers/specs/
```

## 9. Cost guard

AWS Budgets monthly cost budget of $20, with email notifications at 80% actual spend and 100% forecasted spend. The email address comes from `var.budget_email` (`sensitive = true`), supplied in CI by the GitHub secret `BUDGET_EMAIL`.

## 10. CI/CD

### Bootstrap (run once, locally, `--profile dosaki`)

- S3 bucket for Terraform state (versioned, private). The main stack uses `backend "s3"` with `use_lockfile = true`.
- GitHub OIDC provider `token.actions.githubusercontent.com`.
- Role `minecraft-deploy`: its trust policy accepts only `sub = repo:dosaki/minecraft-server:ref:refs/heads/main`. It has permissions to manage the stack's resources, send SSM commands to the instance, and stop it.
- Role `minecraft-plan`: its trust policy accepts `repo:dosaki/minecraft-server:pull_request` and `…:ref:refs/heads/main`. It has read-only permissions plus read access to the state bucket.

### GitHub configuration

- Repository variables (not secrets): `AWS_ACCOUNT_ID`, `AWS_REGION=eu-west-1`.
- Secret: `BUDGET_EMAIL`.
- Branch protection on `main`: changes come in through PRs, and `ci.yml` must pass.

### `ci.yml` (on `pull_request`)

1. `pytest` for `lambda/waker` and `server/lib`.
2. `shellcheck` on `server/bin/*.sh` and `scripts/*.sh`.
3. `terraform fmt -check -recursive` and `terraform validate`.
4. `terraform plan` using `minecraft-plan`. This step only runs when the PR comes from this repository; fork PRs get no OIDC token and skip it.

### `deploy.yml` (on `push` to `main`, `concurrency: { group: deploy, cancel-in-progress: false }`)

1. Assume `minecraft-deploy`. Run `terraform plan -detailed-exitcode -out=tfplan`.
   - Exit code 0 (no changes): finish successfully without touching the server.
   - Exit code 1: fail.
   - Exit code 2: continue.
2. Set SSM `/minecraft/maintenance` to `true`.
3. If the instance is `running`:
   1. SSM Run Command → `mc-rcon say Shutdown for updates in 5 minutes`.
   2. Sleep 240 s → `mc-rcon say Shutdown for updates in 1 minute`. Sleep 60 s.
   3. SSM Run Command → `mc-shutdown`. The command is killed when the OS powers off, so its result is ignored. Success is judged only by the next step.
   4. `aws ec2 wait instance-stopped` (timeout 10 minutes; fail the job on timeout).
4. If the instance is `pending` (it slipped in before maintenance was set): wait for `running`, then go to step 3.
5. `terraform apply tfplan`.
6. **Always** (`if: always()`): set `/minecraft/maintenance` to `false`.

The server stays stopped after a deploy. The next connection wakes it with the new configuration.

## 11. Secrets and public-repo hygiene

| Item | Where it lives |
|---|---|
| Player usernames / ops | SSM `/minecraft/players` (SecureString), set by hand with `scripts/set-players.sh` |
| RCON password | Terraform `random_password` → SSM SecureString (also in private, encrypted state) |
| Budget email | GitHub secret → `TF_VAR_budget_email`, `sensitive = true` |
| AWS account ID | GitHub repo variable |
| AWS credentials | None stored. OIDC in CI, `--profile dosaki` locally |

## 12. Testing

- **Unit tests:**
  - `lambda/waker`: name matching (case variants, trailing dot, SRV vs A, `map.` and other names ignored); maintenance flag; each instance state; the `IncorrectInstanceState` race. AWS calls are mocked with `botocore.stub.Stubber`.
  - `server/lib/gfs.py`: first backup ever; same day (son overwrite only); new day in the same week; new ISO week; new month; year boundary with ISO week 53/01.
- **Static checks:** shellcheck, `terraform validate`, `terraform fmt`.
- **End-to-end smoke test after the first deploy:**
  1. With the instance stopped, run `dig minecraft.dosaki.net @8.8.8.8`. Check the instance goes to `pending` within about a minute and the A record changes to the new IP.
  2. Run `dig map.minecraft.dosaki.net`. Check the instance does **not** start.
  3. Join from a Minecraft client on the whitelist; check that a non-whitelisted account is rejected.
  4. Temporarily set the idle timer to 2 minutes. Check that the backup objects appear (son, father, grandfather, latest on the first run) and that the instance reaches `stopped`.
  5. Open `https://map.minecraft.dosaki.net` while the instance is stopped and check it loads.
  6. Merge a trivial config change. Check the broadcast messages, the shutdown, the apply, and that the maintenance flag is reset.

## 13. Out of scope

- Live player markers on the map.
- Bedrock or crossplay support.
- Notifications when the server is up (e.g. Discord).
- Multiple worlds or servers.
- Automated restore testing.
