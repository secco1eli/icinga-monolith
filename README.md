# Icinga2 Monolith Setup

Single-server monitoring stack on Ubuntu 20.04 / 22.04 / 24.04.

## Stack

| Component    | Role                        |
|--------------|-----------------------------|
| Icinga2      | Monitoring engine           |
| IcingaDB     | Database connector          |
| Redis        | Message bus (Icinga ↔ DB)  |
| MariaDB      | Persistent storage          |
| IcingaWeb2   | Web UI                      |
| Apache2+PHP  | Web server                  |

## Deploy

```bash
sudo bash setup.sh
```

Credentials are auto-generated and saved to `/etc/icinga-setup/credentials.env`.

You can pre-set passwords via environment variables:

```bash
ICINGA_DB_PASS=mypass \
ICINGAWEB_DB_PASS=mypass2 \
ICINGAWEB_ADMIN_PASS=myadminpass \
sudo -E bash setup.sh
```

After setup, open: `http://<server-ip>/icingaweb2`
Login: `admin` / `<generated password shown in output>`

## Directory Structure

```
icinga/
├── setup.sh                    # Main deployment script
├── README.md
├── icinga2/
│   └── conf.d/
│       ├── hosts.conf          # Hosts to monitor
│       ├── services.conf       # Service apply rules
│       ├── users.conf          # Notification contacts
│       └── notifications.conf  # Notification apply rules
└── icingaweb2/
    └── modules/                # Extra IcingaWeb2 module configs
```

## Adding Hosts

Edit [icinga2/conf.d/hosts.conf](icinga2/conf.d/hosts.conf):

```conf
object Host "my-server" {
  import "generic-host"
  address = "192.168.1.10"
  vars.os = "Linux"
  vars.disks["disk /"] = { disk_partitions = "/" }
  vars.http_vhosts["web"] = { http_uri = "/" }
  vars.notification["mail"] = {
    groups = [ "icingaadmins" ]
  }
}
```

Then reload Icinga2:

```bash
sudo systemctl reload icinga2
```

## Useful Commands

```bash
# Check Icinga2 config
sudo icinga2 daemon -C

# Reload config
sudo systemctl reload icinga2

# View credentials
sudo cat /etc/icinga-setup/credentials.env

# Service status
sudo systemctl status icinga2 icingadb redis-server mariadb apache2

# Logs
sudo journalctl -u icinga2 -f
sudo journalctl -u icingadb -f
sudo tail -f /var/log/apache2/error.log
```

## Re-deploying

The script is idempotent for package installation. For a fresh re-deploy on a clean machine, just run `setup.sh` again. On an existing machine with data, re-running will reset passwords — back up `/etc/icinga-setup/credentials.env` first.
