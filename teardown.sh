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
echo "    - Cron jobs: /etc/cron.d/icinga-bsp-poll"
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

# ── 2. Remove packages ────────────────────────────────────────────────────────
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

# ── 3. Drop databases ─────────────────────────────────────────────────────────
log "Dropping databases..."
mysql -e "DROP DATABASE IF EXISTS icingadb; DROP DATABASE IF EXISTS icingaweb2;" 2>/dev/null || true

# ── 4. Remove config and data dirs ───────────────────────────────────────────
log "Removing config and data directories..."
rm -rf \
    /etc/icinga2 \
    /etc/icingadb \
    /etc/icingaweb2 \
    /etc/icinga-setup \
    /var/lib/icinga2 \
    /var/lib/redis \
    /var/log/icinga2 \
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
log "Removing cron jobs and logs..."
rm -f /etc/cron.d/icinga-bsp-poll
rm -f /var/log/bsp-poll.log

# ── 7. Remove Go ──────────────────────────────────────────────────────────────
log "Removing Go..."
rm -rf /usr/local/go /etc/profile.d/golang.sh

# ── 8. Remove Icinga apt repo ─────────────────────────────────────────────────
log "Removing Icinga apt repository..."
rm -f /etc/apt/sources.list.d/icinga.list /usr/share/keyrings/icinga-keyring.gpg
apt-get update -qq 2>/dev/null || true

log "Teardown complete. You can now re-run: sudo bash setup.sh"
