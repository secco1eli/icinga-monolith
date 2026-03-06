# Architecture — QuestDB → Icinga2 Data Pipeline

## Stack Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  QuestDB  (time-series source)                                   │
│  Tables: bsp, cpu, ...                                           │
└───────────────┬──────────────────────────────────────────────────┘
                │  HTTP REST  (basic auth)
                │
        ┌───────┴───────────────────────────────────────┐
        │                                               │
        ▼                                               ▼
┌───────────────────────┐               ┌───────────────────────────┐
│  import-hosts-        │               │  bsp-poll  (cron, 2 min)  │
│  questdb.sh           │               │  scripts/checks/bsp-poll  │
│  (runs once at setup  │               │                           │
│   or manually)        │               │  Queries QuestDB, checks  │
│                       │               │  BSP timestamp freshness, │
│  SELECT DISTINCT host │               │  submits OK/CRIT/UNKNOWN  │
│  FROM cpu             │               │  per host                 │
└──────────┬────────────┘               └──────────────┬────────────┘
           │  HTTPS  (icinga-scripts API user)          │  HTTPS
           │  PUT /v1/objects/hosts/<name>              │  POST /v1/actions/process-check-result
           ▼                                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  Icinga2 API  (:5665)                                            │
│                                                                  │
│  ┌─────────────────────────┐   ┌──────────────────────────────┐  │
│  │  Host objects           │   │  Passive service results     │  │
│  │  template: linux-player │   │  service: BSP-poll           │  │
│  │  enable_passive_checks  │   │  status: OK / CRITICAL /     │  │
│  └─────────────────────────┘   │          UNKNOWN             │  │
│                                └──────────────────────────────┘  │
└──────────────────────────────────┬───────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
          ┌──────────────────┐         ┌──────────────────────┐
          │  IcingaDB        │         │  Notifications       │
          │  (Redis → MariaDB│         │  HaloITSM via        │
          │   persistence)   │         │  notify-*-halo.sh    │
          └──────────────────┘         └──────────────────────┘
                    │
                    ▼
          ┌──────────────────┐
          │  IcingaWeb2      │
          │  (web dashboard) │
          └──────────────────┘
```

---

## Host Import

**Script:** `scripts/import-hosts-questdb.sh`
**Trigger:** Runs automatically at the end of `setup.sh`, or manually.

```
QuestDB
  SELECT DISTINCT host AS host_name, address FROM cpu
         │
         ▼
  For each host:
    PUT /v1/objects/hosts/<host_name>
      templates: ["linux-player"]
      enable_active_checks: false
      enable_passive_checks: true
         │
         ├─ 200 Created  → host created
         ├─ 422 Exists   → POST to update display_name / address
         └─ error        → logged, skipped
```

Hosts are created with the `linux-player` template which marks them as passive-only (`enable_active_checks = false`). Icinga2 will not actively ping or check them — all status comes from passive submissions.

---

## Passive Checks

### How Passive Checks Work in Icinga2

1. A `Service` object exists on a host with `enable_passive_checks = true`
2. An external process submits a result via `POST /v1/actions/process-check-result`
3. Icinga2 accepts the result and updates the service state immediately
4. If no result is received within the `check_freshness` window, Icinga2 marks the service stale (UNKNOWN)

The `BSP-poll` service is applied to all `linux-player` hosts via an apply rule in `icinga2/conf.d/services.conf`. It exists regardless of whether the cron job is running — the cron job is what feeds it results.

### BSP-poll

**Source:** `scripts/checks/bsp-poll.go`
**Cron:** Every 2 minutes via `/etc/cron.d/icinga-bsp-poll`
**Log:** `/var/log/bsp-poll.log`

```
Cron (*/2 * * * *)
  └─► run-bsp-poll.sh
        Sources config.env + secrets.env
        Sets env vars: QUESTDB_URL, ICINGA_API_BASE, ICINGA_API_USER, ICINGA_API_PASS
        Runs: bsp-poll --once
                │
                ▼
        Query QuestDB:
          SELECT host, timestamp
          FROM bsp
          LATEST ON timestamp
          PARTITION BY host
                │
                ▼
        For each host:
          age = now - timestamp
          ├─ age < 15 min  → exit_status=0  (OK)
          ├─ age >= 15 min → exit_status=2  (CRITICAL: stale timestamp)
          └─ no timestamp  → exit_status=3  (UNKNOWN)
                │
                ▼
        POST /v1/actions/process-check-result
          filter: host.name=="<host>" && service.name=="BSP-poll"
          exit_status: 0 / 2 / 3
          plugin_output: "OK: timestamp recent (...), age=30s"
                │
                ▼
        State saved to /var/lib/icinga2/bsp.state.json
        (only changed states are re-posted on subsequent runs)
```

Hosts present in Icinga2 but absent from QuestDB are posted as UNKNOWN (`host missing from QuestDB`).

---

## Adding a New Passive Check

1. **Add a Go source file** in `scripts/checks/` (or add a new `Metric` entry to `bsp-poll.go`)
2. **Add an apply rule** in `icinga2/conf.d/services.conf`:
   ```
   apply Service "My-New-Check" {
     import "generic-service"
     check_command         = "dummy"
     enable_active_checks  = false
     enable_passive_checks = true
     assign where "linux-player" in host.templates
   }
   ```
3. **Deploy the config** and reload Icinga2:
   ```bash
   sudo cp icinga2/conf.d/services.conf /etc/icinga2/conf.d/services.conf
   sudo icinga2 daemon -C && sudo pkill -HUP icinga2
   ```
4. **Wire up the cron job** in `setup.sh` under the `ENABLE_PASSIVE_CHECKS` block

---

## Credential Flow

```
scripts/config.env      (gitignored — create from config.env.example)
  QUESTDB_HOST, QUESTDB_PORT
  ICINGA2_HOST, ICINGA2_PORT, ICINGA2_USER

scripts/secrets.env     (gitignored — create from secrets.env.example)
  QUESTDB_USER, QUESTDB_PASS
  ICINGA2_PASS           ← auto-patched by setup.sh from api-users.conf
  HALO_USER, HALO_PASS

Both files are copied to /opt/icinga-scripts/ by setup.sh.
Scripts source lib.sh, which loads both files at runtime.
The bsp-poll binary reads them via run-bsp-poll.sh (exports as env vars).
```
