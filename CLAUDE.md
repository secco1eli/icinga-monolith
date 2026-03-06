# Icinga2 Monolith - Project Context

## What this is
A single-server Icinga2 monitoring stack with a deployment script (`setup.sh`) and custom scripts for QuestDB integration. The goal is to auto-import hosts and submit passive checks from QuestDB into Icinga2.

## Stack
| Component | Version | Role |
|---|---|---|
| Icinga2 | latest | Monitoring engine |
| IcingaDB | 1.5.1 | DB connector (reads Redis, writes MariaDB) |
| icingadb-web | 1.3.0 | IcingaWeb2 module for IcingaDB |
| Redis | - | Message bus between Icinga2 and IcingaDB |
| MariaDB | 10.11 | Persistent storage |
| IcingaWeb2 | latest | Web UI |
| Apache2 + PHP | - | Web server |
| Go | 1.22.5 | For custom integration scripts |

## Critical config gotchas (hard-won fixes)

### IcingaDB-web Redis config
- Config file: `/etc/icingaweb2/modules/icingadb/redis.ini` (NOT config.ini)
- Section name: `[redis1]` (NOT `[redis]`)
- Default port in source is hardcoded as 6380 (`IcingaRedis.php: DEFAULT_PORT = 6380`)
- Must explicitly set port = 6379 or it ignores the config and uses the default

### Port layout
- Redis (redis-server): **6379**
- IcingaDB: connects TO Redis on 6379, no own listener in v1.5.1
- Icinga2 IcingaDB feature: **6379**
- IcingaWeb2 icingadb module (redis.ini): **6379**

### IcingaDB logging output
- Valid values: `console` or `systemd-journald` (NOT `systemd`)
- WSL2: use `console`
- Real server: use `systemd-journald`

### `svc` fallback for WSL2 (no systemd)
- `svc enable --now <name>` must detect `--now` explicitly and call `service <name> start`
- The `enable` case in the fallback `case` statement maps to `true` (no-op) — `--now` is not inferred
- After starting MariaDB, always wait for the socket with `mysqladmin ping` before running `mysql` commands — the socket at `/run/mysqld/mysqld.sock` may not be ready immediately

### Admin password on re-runs
- Use `INSERT ... ON DUPLICATE KEY UPDATE` not `INSERT IGNORE`
- Credentials saved to `/etc/icinga-setup/credentials.env`

### Hostname on deployment
- `setup.sh` auto-replaces `localhost` host object name with `hostname -f`
- Keeps `localhost`/`127.0.0.1` in repo; only replaces in live `/etc/icinga2/conf.d/`

## File locations (live server)
| What | Path |
|---|---|
| Icinga2 config | `/etc/icinga2/conf.d/` |
| IcingaDB config | `/etc/icingadb/config.yml` |
| IcingaWeb2 config | `/etc/icingaweb2/` |
| IcingaDB module Redis config | `/etc/icingaweb2/modules/icingadb/redis.ini` |
| Custom scripts | `/opt/icinga-scripts/` |
| Credentials | `/etc/icinga-setup/credentials.env` |

## Repo structure
```
setup.sh                          # Full install script (idempotent)
icinga2/conf.d/                   # Icinga2 config (copied to /etc/icinga2/conf.d/ on deploy)
scripts/
  config.env                      # Connection config only (gitignored, has .example)
  config.env.example              # Template
  lib.sh                          # Shared bash helpers (Icinga2 API, QuestDB query)
  import-hosts-questdb.sh         # Import hosts from QuestDB (bash, working)
  import-timeperiods-questdb.go   # Per-host timeperiods from QuestDB (TODO)
  passive-check.sh                # Generic passive check submitter (bash, working)
  checks/
    check-passive-questdb.go      # Passive checks from QuestDB (TODO)
    check-questdb.sh              # QuestDB health check (working)
    check-example.sh              # Template for new checks
```

## Planned Go scripts
Each Go script owns its own QuestDB query as a `const` in the file.
Connection config (host, port, credentials) is read from `scripts/config.env`.

- `import-timeperiods-questdb.go` — query QuestDB for per-host timeperiods, create TimePeriod objects in Icinga2, assign to hosts
- `checks/check-passive-questdb.go` — query QuestDB for check results, submit as passive checks to Icinga2 API, mark rows processed

## Deploy workflow
```bash
# On the server after changes
git pull
sudo cp icinga2/conf.d/* /etc/icinga2/conf.d/
sudo icinga2 daemon -C && sudo systemctl reload icinga2
```

## Useful commands
```bash
# Validate config
sudo icinga2 daemon -C

# Reload Icinga2
sudo systemctl reload icinga2

# Check all service status
sudo systemctl status icinga2 icingadb redis-server mariadb apache2

# View credentials
sudo cat /etc/icinga-setup/credentials.env

# Icinga2 API test
curl -sSk -u icingaweb2:<pass> https://localhost:5665/v1/status
```
