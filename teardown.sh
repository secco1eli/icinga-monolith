#!/usr/bin/env bash
# Icinga2 Monolith Teardown Script
# Removes all installed components so setup.sh can be re-run cleanly.
# config.env and secrets.env in /opt/icinga-scripts/ are always preserved.
#
# Usage:
#   sudo bash teardown.sh
set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo "  WARNING: This will permanently remove the Icinga2 stack:"
echo "    - Packages: icinga2, icingadb, icingaweb2, mariadb, redis, apache2"
echo "    - Databases: icingadb, icingaweb2"
echo "    - Config dirs: /etc/icinga2, /etc/icingadb, /etc/icingaweb2, /etc/icinga-setup"
echo "    - Data dirs: /var/lib/icinga2, /var/lib/redis"
echo "    - Cron jobs: /etc/cron.d/icinga-* and /etc/logrotate.d/icinga-checks"
echo "    - Scripts: /opt/icinga-scripts (config.env and secrets.env always preserved)"
echo ""
read -r -p "  Type 'yes' to confirm: " CONFIRM
echo ""
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

log "Starting teardown..."

# ── 1. Stop services ──────────────────────────────────────────────────────────
log "Stopping services..."
for svc in icinga2 icingadb redis-server apache2 mariadb; do
    service "$svc" stop 2>/dev/null || true
done

# ── 2. Drop databases and users (must happen before MariaDB is purged) ────────
log "Dropping databases and users..."
mysql -e "DROP DATABASE IF EXISTS icingadb; DROP DATABASE IF EXISTS icingaweb2; DROP USER IF EXISTS 'icingadb'@'localhost'; DROP USER IF EXISTS 'icingaweb2'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true

# ── 3. Remove packages ────────────────────────────────────────────────────────
log "Purging packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y \
    icinga2 icingadb icingadb-web icingaweb2 \
    mariadb-server mariadb-client mariadb-common \
    redis-server apache2 apache2-utils \
    libapache2-mod-php \
    php-mysql php-curl php-xml php-gd php-mbstring php-intl php-zip php-imagick \
    2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# ── 4. Remove config and data dirs ───────────────────────────────────────────
log "Removing config and data directories..."
rm -rf \
    /etc/icinga2 \
    /etc/icingadb \
    /etc/icingaweb2 \
    /etc/icinga-setup \
    /etc/redis \
    /etc/mysql \
    /var/lib/icinga2 \
    /var/lib/redis \
    /var/lib/mysql \
    /var/log/icinga2 \
    /var/log/icingadb.log \
    /var/log/icinga-setup.log \
    /run/icinga2 \
    /run/icingadb

# ── 5. Remove custom scripts ──────────────────────────────────────────────────
if [[ -d /opt/icinga-scripts ]]; then
    log "Removing /opt/icinga-scripts (preserving config.env and secrets.env)..."
    find /opt/icinga-scripts \
        -not -name 'config.env' \
        -not -name 'secrets.env' \
        -not -path '/opt/icinga-scripts' \
        -delete 2>/dev/null || true
fi

# ── 6. Remove cron jobs and logs ──────────────────────────────────────────────
log "Removing cron jobs, logrotate config, and logs..."
# All check cron jobs, import-hosts cron, and all icinga-prefixed log files
for _f in /etc/cron.d/icinga-* /var/log/icinga-*; do
    rm -f "$_f"
done
rm -f /etc/logrotate.d/icinga-checks

# ── 7. Remove Go ──────────────────────────────────────────────────────────────
log "Removing Go..."
rm -rf /usr/local/go /etc/profile.d/golang.sh

# ── 8. Remove apt repos ───────────────────────────────────────────────────────
log "Removing Icinga and MariaDB apt repositories..."
rm -f /etc/apt/sources.list.d/icinga.list /usr/share/keyrings/icinga-keyring.gpg
# mariadb_repo_setup adds entries under /etc/apt/sources.list.d/ with "mariadb" in the name
rm -f /etc/apt/sources.list.d/mariadb.list /usr/share/keys/mariadb-keyring*.gpg \
      /etc/apt/trusted.gpg.d/mariadb*.gpg 2>/dev/null || true
# It may also write to /etc/apt/sources.list.d/mariadb*.list
find /etc/apt/sources.list.d/ -name 'mariadb*' -delete 2>/dev/null || true
apt-get update -qq 2>/dev/null || true

# ── 9. WSL2 invoke-rc.d backup cleanup ────────────────────────────────────────
if [[ -f /usr/sbin/invoke-rc.d.pre-icinga-setup ]]; then
    log "Restoring invoke-rc.d from pre-icinga-setup backup..."
    mv /usr/sbin/invoke-rc.d.pre-icinga-setup /usr/sbin/invoke-rc.d
fi

log "Teardown complete. You can now re-run: sudo bash setup.sh"
