# Icinga2 Monolith Setup

Infrastructure-as-code for a single-server Icinga2 monitoring stack. The setup script is fully idempotent and WSL2-compatible, so you can spin up, tear down, and iterate on the full stack locally before deploying to a real server.

Runs on Ubuntu 20.04 / 22.04 / 24.04 (bare metal, VM, or WSL2).

See [docs/architecture.md](docs/architecture.md) for the QuestDB → Icinga2 data pipeline and passive check design.

## Stack

| Component    | Role                        |
|--------------|-----------------------------|
| Icinga2      | Monitoring engine           |
| IcingaDB     | Database connector          |
| Redis        | Message bus (Icinga ↔ DB)  |
| MariaDB      | Persistent storage          |
| IcingaWeb2   | Web UI                      |
| Apache2+PHP  | Web server                  |
| Go           | Custom integration scripts  |

## Before You Deploy

Both config files live in `scripts/` and are gitignored — they are never committed. Create them from the examples before running `setup.sh`.

```bash
cp scripts/config.env.example scripts/config.env
cp scripts/secrets.env.example scripts/secrets.env
```

### 1. scripts/config.env — connection settings

| Variable | Description | Required for |
|---|---|---|
| `ICINGA2_HOST` | Icinga2 API host (`localhost` for monolith) | always |
| `ICINGA2_PORT` | Icinga2 API port (`5665`) | always |
| `ICINGA2_USER` | API user for scripts (`icinga-scripts`) | always |
| `QUESTDB_HOST` | Hostname or IP of your QuestDB instance | QuestDB host import |
| `QUESTDB_PORT` | QuestDB HTTP port (`9000`) | QuestDB host import |
| `ICINGA2_HOST_TEMPLATE` | Host template for imported hosts (`linux-player`) | QuestDB host import |
| `ICINGA2_HOST_ZONE` | Zone for imported hosts — leave blank for monolith | QuestDB host import |
| `HALO_URL` | HaloITSM API endpoint | HaloITSM notifications |
| `ICINGA2_WEB_URL` | Base URL of your IcingaWeb2 UI | HaloITSM notifications |

### 2. scripts/secrets.env — credentials

| Variable | Description | Required for |
|---|---|---|
| `QUESTDB_USER` | QuestDB username | QuestDB host import |
| `QUESTDB_PASS` | QuestDB password | QuestDB host import |
| `ICINGA2_PASS` | Leave blank — auto-filled by `setup.sh` | always (auto-set) |
| `HALO_USER` | HaloITSM client ID | HaloITSM notifications |
| `HALO_PASS` | HaloITSM client secret | HaloITSM notifications |

`ICINGA2_PASS` is automatically patched in by `setup.sh` after generating the `icinga-scripts` API user.

**QuestDB host import** runs automatically during setup if `QUESTDB_HOST` is set to something other than `localhost`. If `QUESTDB_HOST` or credentials are not set, the import step is skipped silently.

**HaloITSM notifications** require `HALO_URL`, `HALO_USER`, `HALO_PASS`, and `ICINGA2_WEB_URL` to be set, plus the `ENABLE_HALO_NOTIFICATIONS=true` flag at deploy time (see below).

## Deploy

```bash
sudo bash setup.sh
```

`setup.sh` will:
- Install and configure the full stack
- Auto-generate Icinga2/MariaDB passwords (saved to `/etc/icinga-setup/credentials.env`)
- Create a dedicated `icinga-scripts` API user with minimal permissions (host query/modify only)
- Copy `scripts/` to `/opt/icinga-scripts/` including your config and secrets
- Auto-patch `ICINGA2_PASS` in `/opt/icinga-scripts/secrets.env` with the `icinga-scripts` API password
- Run `import-hosts-questdb.sh` to import hosts from QuestDB (skipped if `QUESTDB_HOST` is `localhost`)

After setup, open: `http://<server-ip>/icingaweb2`
Login: `admin` / password shown in setup output, or `sudo cat /etc/icinga-setup/credentials.env`

You can pre-set the web admin password via environment variable:

```bash
ICINGAWEB_ADMIN_PASS=mypass sudo -E bash setup.sh
```

### HaloITSM notifications (optional)

HaloITSM notifications are **not deployed by default**. To enable them:

```bash
ENABLE_HALO_NOTIFICATIONS=true sudo -E bash setup.sh
```

This copies `icinga2/zones.d/master/notification_apply.conf` and `notification_templates.conf` to `/etc/icinga2/zones.d/master/`, deploying the notification apply rules, templates, NotificationCommand objects, and the `halo-digital-user`.

Make sure `HALO_URL`, `ICINGA2_WEB_URL`, `HALO_USER`, and `HALO_PASS` are set in your `config.env` and `secrets.env` before running (see the table above).

The notification scripts (`notify-host-halo.sh`, `notify-service-halo.sh`) are always installed to `/opt/icinga-scripts/` — only the Icinga2 config that wires them in is gated behind the flag.

### BSP-poll passive checks (optional)

`setup.sh` will prompt during install:

```
  Enable passive checks (BSP-poll cron job)? [y/N]
```

Answering **y** will:
- Compile `scripts/checks/bsp-poll.go` into a binary at `/opt/icinga-scripts/checks/bsp-poll`
- Install `/etc/cron.d/icinga-bsp-poll` to run every 2 minutes

The cron job calls `run-bsp-poll.sh`, which sources `config.env`/`secrets.env` and submits passive check results to Icinga2 for every `linux-player` host. The `BSP-poll` service is always registered on those hosts — the cron job is what feeds it results.

To skip the prompt and pre-set the answer:

```bash
ENABLE_PASSIVE_CHECKS=yes sudo -E bash setup.sh   # enable
ENABLE_PASSIVE_CHECKS=no  sudo -E bash setup.sh   # skip
```

Logs are written to `/var/log/bsp-poll.log`.

## Directory Structure

```
icinga/
├── setup.sh                          # Main deployment script (idempotent)
├── icinga2/
│   ├── conf.d/                       # Icinga2 config (copied to /etc/icinga2/conf.d/)
│   │   └── templates.conf            # Defines generic-host, linux-player, notification templates
│   └── zones.d/master/               # Optional: deployed when ENABLE_HALO_NOTIFICATIONS=true
│       ├── notification_templates.conf  # NotificationCommands, templates, halo-digital-user
│       └── notification_apply.conf      # apply Notification rules for host and service
└── scripts/
    ├── config.env.example            # Non-sensitive config template (commit this)
    ├── config.env                    # Your config — gitignored, create from example
    ├── secrets.env.example           # Secrets template (commit this)
    ├── secrets.env                   # Your credentials — gitignored, create from example
    ├── lib.sh                        # Shared helpers (Icinga2 API, QuestDB query)
    ├── import-hosts-questdb.sh       # Import hosts from QuestDB (dry-run supported)
    ├── notify-host-halo.sh           # HaloITSM host notification script
    ├── notify-service-halo.sh        # HaloITSM service notification script
    └── checks/
        ├── bsp-poll.go               # BSP-poll passive check binary (built by setup.sh)
        ├── run-bsp-poll.sh           # Cron wrapper — sources env files, runs bsp-poll
        └── check-questdb.sh          # QuestDB health check
```

## Host Import from QuestDB

`setup.sh` automatically runs `import-hosts-questdb.sh` after install if `QUESTDB_HOST` is not `localhost`.

The script queries `SELECT DISTINCT host FROM cpu` in QuestDB and creates a passive host object in Icinga2 for each result, using the `linux-player` template (defined in `icinga2/conf.d/templates.conf`).

To re-run manually:

```bash
sudo bash /opt/icinga-scripts/import-hosts-questdb.sh
```

## Useful Commands

```bash
# Check Icinga2 config
sudo icinga2 daemon -C

# Reload config (use pkill -HUP on WSL2 where systemctl is unavailable)
sudo systemctl reload icinga2
sudo pkill -HUP icinga2

# View generated credentials
sudo cat /etc/icinga-setup/credentials.env

# Service status
sudo systemctl status icinga2 icingadb redis-server mariadb apache2

# Logs
sudo journalctl -u icinga2 -f
sudo journalctl -u icingadb -f
sudo tail -f /var/log/apache2/error.log

# Icinga2 API test
curl -sSk -u root:<pass> https://localhost:5665/v1/status
```

## Re-deploying

The script is idempotent for package installation. For a fresh re-deploy on a clean machine, just run `setup.sh` again. On an existing machine with data, re-running will reset passwords — back up `/etc/icinga-setup/credentials.env` first.