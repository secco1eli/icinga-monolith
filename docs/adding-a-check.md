# Adding a New Passive Check

This guide covers everything needed to add a new Go-based passive check to the monitoring stack.

## Overview

Adding a check involves four files:

| File | Location | Purpose |
|---|---|---|
| `services.conf` | `icinga2/conf.d/` | Service definition — tells Icinga the check exists |
| `<name>.toml` | `scripts/checks/` | Config: query, thresholds, cron schedule, service name |
| `<name>.go` | `scripts/checks/` | Logic: query QuestDB, evaluate results, post to Icinga2 |
| `run-<name>.sh` | `scripts/checks/` | Cron wrapper: sources credentials, invokes the binary |

`setup.sh` auto-discovers checks by scanning `scripts/checks/*.toml` and handles building, cron install, and service config deploy in one run.

## Step-by-step

### 1. Define the Icinga service

Add an `apply Service` block in [icinga2/conf.d/services.conf](../icinga2/conf.d/services.conf).

The `assign where` clause controls which hosts the service appears on — use the same filter your Go binary will query. The service name here must exactly match `service_name` in your TOML.

```icinga2
// My new check — passive results submitted by my-check cron job
apply Service "My Check" {
  import "generic-service"

  check_command         = "dummy"
  enable_active_checks  = false
  enable_passive_checks = true

  // Default state shown in Icinga until first passive result arrives
  vars.dummy_state = 3
  vars.dummy_text  = "UNKNOWN: no result received yet"

  // Only apply to hosts imported with the linux-player template
  assign where "linux-player" in host.templates
}
```

Optionally add a heartbeat service (fires CRITICAL if the cron job stops running):

```icinga2
// My new check heartbeat — submitted by run-my-check.sh after each cron run
apply Service "My Check Last Run" {
  import "generic-service"

  check_command         = "dummy"
  enable_active_checks  = true
  enable_passive_checks = true
  check_interval        = 10m
  retry_interval        = 10m

  vars.dummy_state = 2
  vars.dummy_text  = "CRITICAL: no heartbeat received from my-check in 10 minutes"

  assign where host.vars.icinga_master
}
```

Commit the change, then deploy via `setup.sh` (see Step 6 — it copies `services.conf` automatically).

### 2. Create `<name>.toml`

Copy [bsp-poll.toml](bsp-poll.toml) as a starting point and edit every section.

Key fields to change:

```toml
[schedule]
cron = "*/5 * * * *"       # how often to run

[icinga]
service_name = "My Check"  # must match services.conf exactly

[questdb]
timestamp_column = "timestamp"
query = """
SELECT host, timestamp
FROM my_table
LATEST ON timestamp
PARTITION BY host
"""

[thresholds]
# Timestamps: age since last row before alerting
crit_minutes   = 15    # CRITICAL if no data for > 15 min
warn_minutes   = 10    # WARNING  if no data for > 10 min (0 = disabled, skip straight to CRITICAL)
resync_seconds = 3600  # force-repost all results every 1 hour

# Per-host overrides (optional, ordered, first match wins):
# [[thresholds.host_overrides]]
# pattern      = "batch-server-*"
# crit_minutes = 120
# warn_minutes = 90
```

The `[state]`, `[reliability]`, and `[schedule]` sections rarely need changing from the defaults.

### Threshold types

**Timestamp staleness** (current bsp-poll pattern): query returns a `timestamp` column.
The check posts OK/WARNING/CRITICAL based on how old the latest row is.

```toml
[thresholds]
crit_minutes = 15   # CRITICAL if > 15 min since last row
warn_minutes = 10   # WARNING  if > 10 min (0 = skip warning)
```

**Numeric value** (for a different Go file with `evaluateThreshold`): query returns a numeric column.
The check posts WARNING/CRITICAL if the value exceeds the thresholds.

```toml
[thresholds]
# For a numeric check the Go file reads warn_above / crit_above from TOML.
# See evaluateThreshold() in bsp-poll.go for the reference implementation.
warn_above = 80    # WARNING  if value > 80
crit_above = 90    # CRITICAL if value > 90
column     = "cpu_pct"   # which query column to evaluate

[[thresholds.host_overrides]]
pattern    = "high-volume-*"
warn_above = 95
crit_above = 99
```

Per-host overrides always mirror the same fields as the global `[thresholds]` block — whatever your check type uses globally, you can override per-host pattern.

### 3. Create `<name>.go`

Copy [bsp-poll.go](bsp-poll.go) as a starting point. The binary already handles:
- Loading config from `<name>.toml`
- Fetching hosts from Icinga2
- Querying QuestDB
- Evaluating staleness
- Posting passive results
- State tracking (suppress duplicate posts)
- Worker pool concurrency
- `--cron` and `--dry-run` flags

For a timestamp-based check (the common case), you only need to change the TOML — the Go source can be used as-is if the logic is the same. Copy and rename it only if you need different evaluation logic (e.g., numeric thresholds instead of timestamp staleness).

If you do copy the Go file, the binary name must match the TOML name:
- `my-check.go` → build produces `my-check` → loads `my-check.toml`

### 4. Create `run-<name>.sh`

Copy [run-bsp-poll.sh](run-bsp-poll.sh) and update the binary name:

```bash
cp scripts/checks/run-bsp-poll.sh scripts/checks/run-my-check.sh
# Edit: change "bsp-poll" to "my-check" in the binary invocation line
# Edit: change SERVICE= to match the Icinga heartbeat service name (if using one)
```

The wrapper's job is to source credentials from `config.env`/`secrets.env` and export them as env vars before calling the binary. The binary reads everything else from its TOML.

### 5. Verify Go imports

If you added new imports to a `.go` file, test the module resolves locally:

```bash
cd scripts/checks
go mod tidy   # updates go.sum if needed
go build -o /tmp/test-check ./your-check.go
```

`setup.sh` runs `go mod tidy` automatically on every deploy, so `go.sum` is always kept up to date on the server. Commit any changes to `go.mod` and `go.sum` so developer builds stay in sync.

### 6. Deploy

Commit all four files (`services.conf`, `<name>.toml`, `<name>.go`, `run-<name>.sh`) and push. On the server:

```bash
cd /path/to/icinga-repo   # wherever the repo is checked out on the server
git pull
sudo bash setup.sh
# Answer "y" when prompted for passive checks
```

`setup.sh` handles everything in one run:
1. Copies `icinga2/conf.d/services.conf` → `/etc/icinga2/conf.d/`
2. Validates config (`icinga2 daemon -C`)
3. Reloads Icinga2 (service apply rules take effect)
4. Runs `go mod tidy` and builds all `*.go` files that have a matching `*.toml`
5. Installs `/etc/cron.d/icinga-<name>` from each binary's `--cron` output
6. Writes `/etc/logrotate.d/icinga-checks`

**The service definition must be deployed (step 3) before the first passive result arrives, otherwise Icinga rejects the post.**

To redeploy just one check without running full setup (e.g. after a TOML-only change):

```bash
# On the server
cd /opt/icinga-scripts/checks
sudo /usr/local/go/bin/go build -o my-check my-check.go
sudo chmod +x my-check
CRON=$(./my-check --cron)
echo "$CRON root /opt/icinga-scripts/checks/run-my-check.sh >> /var/log/my-check.log 2>&1" \
  | sudo tee /etc/cron.d/icinga-my-check
sudo chmod 644 /etc/cron.d/icinga-my-check
```

For a TOML-only change (no rebuild needed), just wait for the next cron run — the binary reads its TOML fresh every time it runs.

## Conventions

| Convention | Reason |
|---|---|
| File names: `kebab-case` | Consistent with existing checks |
| Binary name = TOML name = cron file suffix | Auto-discovery relies on this |
| Credentials only in `config.env` / `secrets.env` | Never put passwords in TOML |
| Service name in TOML must match `services.conf` exactly | Icinga rejects unknown service targets |
| Cron schedule defined in TOML, never edit `/etc/cron.d/` directly | setup.sh manages cron files |
| Never edit `/etc/logrotate.d/icinga-checks` directly | setup.sh regenerates it from TOML discovery |

## What goes where

| Setting | Location |
|---|---|
| Cron schedule | `[schedule].cron` in TOML |
| QuestDB query | `[questdb].query` in TOML |
| Staleness thresholds | `[thresholds]` in TOML |
| Per-host threshold overrides | `[[thresholds.host_overrides]]` in TOML |
| Icinga service name | `[icinga].service_name` in TOML + `services.conf` |
| QuestDB host/port | `config.env` (exported by run script) |
| QuestDB credentials | `secrets.env` (exported by run script) |
| Icinga API credentials | `secrets.env` (exported by run script) |
| Check logic (what to evaluate) | `<name>.go` |
| Service definition (intervals, notifications) | `icinga2/conf.d/services.conf` |

## Existing checks

| Check | Source | Config | Cron |
|---|---|---|---|
| BSP-poll | [bsp-poll.go](bsp-poll.go) | [bsp-poll.toml](bsp-poll.toml) | `*/2 * * * *` |
