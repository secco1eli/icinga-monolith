#!/usr/bin/env bash
# Icinga2 Monolith Setup Script
# Ubuntu 20.04 / 22.04 / 24.04
# Stack: Icinga2 + IcingaDB + Redis + MariaDB + IcingaWeb2 + Apache2
set -euo pipefail

# ─── Environment detection ────────────────────────────────────────────────────
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi

# Wrapper: use systemctl if systemd is running, otherwise fall back to service(8)
# Supports multi-service restarts: svc restart svcA svcB svcC
svc() {
    if systemctl is-system-running &>/dev/null 2>&1 || \
       [[ "$(systemctl is-system-running 2>/dev/null)" =~ ^(running|degraded)$ ]]; then
        systemctl "$@"
        return
    fi
    # Fallback for non-systemd environments (WSL2 without systemd)
    local args=("$@")
    local action="${args[0]}"
    local services=("${args[@]:1}")
    # strip flags like --now from service list
    local clean_services=()
    for s in "${services[@]}"; do
        [[ "$s" == --* ]] || clean_services+=("$s")
    done
    # Detect if --now was passed (means enable+start)
    local do_start=false
    for s in "${services[@]}"; do
        [[ "$s" == "--now" ]] && do_start=true
    done

    for name in "${clean_services[@]}"; do
        case "$action" in
            enable)
                $do_start && service "$name" start || true ;;
            start) service "$name" start ;;
            restart)
                if ! service "$name" restart 2>/dev/null; then
                    # No SysV init script (e.g. icingadb) — start binary directly
                    EXEC="$(grep '^ExecStart=' "/lib/systemd/system/${name}.service" 2>/dev/null | sed 's/ExecStart=//' | awk '{print $1}')"
                    if [[ -n "$EXEC" && -x "$EXEC" ]]; then
                        pkill -f "$EXEC" 2>/dev/null || true
                        sleep 1
                        nohup "$EXEC" >> "/var/log/${name}.log" 2>&1 &
                        log "Started ${name} directly (no init script): $EXEC"
                    else
                        log "Warning: could not restart ${name} — no init script or binary found"
                    fi
                fi ;;
            reload)        service "$name" reload ;;
            stop)          service "$name" stop ;;
        esac
    done
}

# IcingaDB log output: systemd-journald on real servers, console on WSL
if $IS_WSL; then
    ICINGADB_LOG_OUTPUT="console"
else
    ICINGADB_LOG_OUTPUT="systemd-journald"
fi

# ─── Configuration ────────────────────────────────────────────────────────────
ICINGA_DB_NAME="icingadb"
ICINGA_DB_USER="icingadb"
ICINGA_DB_PASS="${ICINGA_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)}"

ICINGAWEB_DB_NAME="icingaweb2"
ICINGAWEB_DB_USER="icingaweb2"
ICINGAWEB_DB_PASS="${ICINGAWEB_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)}"

ICINGAWEB_ADMIN_PASS="${ICINGAWEB_ADMIN_PASS:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/icinga-setup.log"

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"; }

# ─── Main ─────────────────────────────────────────────────────────────────────
need_root

# Save credentials early so they aren't lost on failure
mkdir -p /etc/icinga-setup
cat > /etc/icinga-setup/credentials.env <<EOF
ICINGA_DB_NAME=${ICINGA_DB_NAME}
ICINGA_DB_USER=${ICINGA_DB_USER}
ICINGA_DB_PASS=${ICINGA_DB_PASS}
ICINGAWEB_DB_NAME=${ICINGAWEB_DB_NAME}
ICINGAWEB_DB_USER=${ICINGAWEB_DB_USER}
ICINGAWEB_DB_PASS=${ICINGAWEB_DB_PASS}
ICINGAWEB_ADMIN_PASS=${ICINGAWEB_ADMIN_PASS}
EOF
chmod 600 /etc/icinga-setup/credentials.env
log "Credentials saved to /etc/icinga-setup/credentials.env"

# ── 1. System prerequisites ───────────────────────────────────────────────────
log "Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# ── 2. Repositories ───────────────────────────────────────────────────────────
log "Adding Icinga repository..."
curl -sSL https://packages.icinga.com/icinga.key | gpg --dearmor --yes -o /usr/share/keyrings/icinga-keyring.gpg

CODENAME="$(lsb_release -cs)"
# Map supported Ubuntu codenames
case "$CODENAME" in
    focal|jammy|noble) ;;
    *) die "Unsupported Ubuntu release: $CODENAME (need focal/jammy/noble)" ;;
esac

cat > /etc/apt/sources.list.d/icinga.list <<REPO
deb [signed-by=/usr/share/keyrings/icinga-keyring.gpg] https://packages.icinga.com/ubuntu icinga-${CODENAME} main
deb-src [signed-by=/usr/share/keyrings/icinga-keyring.gpg] https://packages.icinga.com/ubuntu icinga-${CODENAME} main
REPO

log "Adding MariaDB repository..."
curl -sSL https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-10.11" --skip-check-installed

apt-get update -qq

# ── 3. Package installation ───────────────────────────────────────────────────
log "Installing Icinga2, IcingaDB, IcingaWeb2, MariaDB, Redis, Apache2..."
apt-get install -y -qq \
    icinga2 \
    icingadb \
    icingadb-web \
    icingaweb2 \
    mariadb-server \
    redis-server \
    apache2 \
    libapache2-mod-php \
    php-mysql \
    php-curl \
    php-xml \
    php-gd \
    php-mbstring \
    php-intl \
    php-zip \
    php-imagick

# ── 4. MariaDB setup ──────────────────────────────────────────────────────────
log "Configuring MariaDB..."
svc enable --now mariadb

# Wait for MariaDB socket to be ready
log "Waiting for MariaDB to be ready..."
for _ in $(seq 1 30); do
    mysqladmin ping --silent 2>/dev/null && break
    sleep 1
done
mysqladmin ping --silent 2>/dev/null || die "MariaDB did not start within 30 seconds"

# Secure installation (non-interactive)
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

# Create IcingaDB database
mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${ICINGA_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${ICINGA_DB_USER}'@'localhost' IDENTIFIED BY '${ICINGA_DB_PASS}';
ALTER USER '${ICINGA_DB_USER}'@'localhost' IDENTIFIED BY '${ICINGA_DB_PASS}';
GRANT ALL PRIVILEGES ON ${ICINGA_DB_NAME}.* TO '${ICINGA_DB_USER}'@'localhost';
CREATE DATABASE IF NOT EXISTS ${ICINGAWEB_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${ICINGAWEB_DB_USER}'@'localhost' IDENTIFIED BY '${ICINGAWEB_DB_PASS}';
ALTER USER '${ICINGAWEB_DB_USER}'@'localhost' IDENTIFIED BY '${ICINGAWEB_DB_PASS}';
GRANT ALL PRIVILEGES ON ${ICINGAWEB_DB_NAME}.* TO '${ICINGAWEB_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Import IcingaDB schema (skip if tables already exist)
log "Importing IcingaDB schema..."
TABLE_COUNT=$(mysql -u "${ICINGA_DB_USER}" -p"${ICINGA_DB_PASS}" "${ICINGA_DB_NAME}" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ICINGA_DB_NAME}';" -sN 2>/dev/null || echo 0)
if [[ "$TABLE_COUNT" -eq 0 ]]; then
    mysql -u "${ICINGA_DB_USER}" -p"${ICINGA_DB_PASS}" "${ICINGA_DB_NAME}" \
        < /usr/share/icingadb/schema/mysql/schema.sql
else
    log "IcingaDB schema already imported, skipping."
fi

# Import IcingaWeb2 schema (skip if tables already exist)
log "Importing IcingaWeb2 schema..."
TABLE_COUNT=$(mysql -u "${ICINGAWEB_DB_USER}" -p"${ICINGAWEB_DB_PASS}" "${ICINGAWEB_DB_NAME}" \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ICINGAWEB_DB_NAME}';" -sN 2>/dev/null || echo 0)
if [[ "$TABLE_COUNT" -eq 0 ]]; then
    mysql -u "${ICINGAWEB_DB_USER}" -p"${ICINGAWEB_DB_PASS}" "${ICINGAWEB_DB_NAME}" \
        < /usr/share/icingaweb2/schema/mysql.schema.sql
else
    log "IcingaWeb2 schema already imported, skipping."
fi

# ── 5. Redis ──────────────────────────────────────────────────────────────────
log "Configuring Redis..."
svc enable --now redis-server
# Bind only to localhost
sed -i 's/^# bind 127.0.0.1/bind 127.0.0.1/' /etc/redis/redis.conf || true
svc restart redis-server

# ── 6. IcingaDB ───────────────────────────────────────────────────────────────
log "Configuring IcingaDB..."
cat > /etc/icingadb/config.yml <<ICINGADB
database:
  host: localhost
  port: 3306
  database: ${ICINGA_DB_NAME}
  user: ${ICINGA_DB_USER}
  password: "${ICINGA_DB_PASS}"

redis:
  host: 127.0.0.1
  port: 6379

logging:
  level: info
  output: ${ICINGADB_LOG_OUTPUT}

retention:
  history-days: 365
  sla-days: 730
ICINGADB

svc enable --now icingadb

# ── 7. Icinga2 ────────────────────────────────────────────────────────────────
log "Configuring Icinga2..."
# Enable features
icinga2 feature enable icingadb
icinga2 feature enable checker
icinga2 feature enable notification
icinga2 feature enable command

# Configure Icinga2 → IcingaDB connection
cat > /etc/icinga2/features-available/icingadb.conf <<ICINGA2CONF
/**
 * IcingaDB feature
 */
object IcingaDB "icingadb" {
  host = "127.0.0.1"
  port = 6379
}
ICINGA2CONF

# Set up API (needed for IcingaWeb2 director / actions)
log "Setting up Icinga2 API..."
icinga2 api setup 2>&1 | tee -a "$LOG_FILE"

# Add icingaweb2 API user
cat > /etc/icinga2/conf.d/api-users.conf <<APIUSERS
/**
 * API users
 */
object ApiUser "root" {
  password = "$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  permissions = [ "*" ]
}

object ApiUser "icingaweb2" {
  password = "$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  permissions = [ "status/query", "actions/*", "objects/modify/*", "objects/query/*" ]
}

object ApiUser "icinga-scripts" {
  password = "$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  permissions = [ "objects/query/Host", "objects/create/Host", "objects/modify/Host" ]
}
APIUSERS

# Copy local zone config from our config directory if present
if [[ -d "${SCRIPT_DIR}/icinga2/conf.d" ]]; then
    log "Copying custom Icinga2 configuration..."
    cp -r "${SCRIPT_DIR}/icinga2/conf.d/"* /etc/icinga2/conf.d/
    # Replace the generic "localhost" host object name with the actual hostname
    SERVER_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    SERVER_IP="$(hostname -I | awk '{print $1}')"
    log "Setting Icinga2 master host to '${SERVER_HOSTNAME}' (${SERVER_IP})..."
    sed -i "s/object Host \"localhost\"/object Host \"${SERVER_HOSTNAME}\"/" \
        /etc/icinga2/conf.d/hosts.conf
    sed -i "s/address  = \"127\.0\.0\.1\"/address  = \"${SERVER_IP}\"/" \
        /etc/icinga2/conf.d/hosts.conf
fi

svc enable icinga2
svc restart icinga2

# ── 8. IcingaWeb2 ─────────────────────────────────────────────────────────────
log "Configuring IcingaWeb2..."
mkdir -p /etc/icingaweb2/{modules,enabledModules}

# Main config
cat > /etc/icingaweb2/config.ini <<WEBCONF
[global]
show_stacktraces = "1"
show_application_state_messages = "1"
config_resource = "icingaweb2_db"
module_path = "/usr/share/icingaweb2/modules"

[logging]
log = "syslog"
level = "ERROR"
application = "icingaweb2"
WEBCONF

# Resources
cat > /etc/icingaweb2/resources.ini <<RESOURCES
[icingaweb2_db]
type = "db"
db = "mysql"
host = "localhost"
port = "3306"
dbname = "${ICINGAWEB_DB_NAME}"
username = "${ICINGAWEB_DB_USER}"
password = "${ICINGAWEB_DB_PASS}"
charset = "utf8mb4"
use_ssl = "0"

[icingadb]
type = "db"
db = "mysql"
host = "localhost"
port = "3306"
dbname = "${ICINGA_DB_NAME}"
username = "${ICINGA_DB_USER}"
password = "${ICINGA_DB_PASS}"
charset = "utf8mb4"
use_ssl = "0"
RESOURCES

# Authentication
cat > /etc/icingaweb2/authentication.ini <<AUTH
[icingaweb2]
backend = "db"
resource = "icingaweb2_db"
AUTH

# Roles
cat > /etc/icingaweb2/roles.ini <<ROLES
[Administrators]
users = "admin"
groups = ""
permissions = "*"
ROLES

# Groups
cat > /etc/icingaweb2/groups.ini <<GROUPS
[icingaweb2]
backend = "db"
resource = "icingaweb2_db"
GROUPS

# Enable icingadb module
mkdir -p /etc/icingaweb2/modules/icingadb
ln -sfn /usr/share/icingaweb2/modules/icingadb /etc/icingaweb2/enabledModules/icingadb 2>/dev/null || true

cat > /etc/icingaweb2/modules/icingadb/config.ini <<ICINGADBMODULE
[icingadb]
resource = "icingadb"
ICINGADBMODULE

# redis.ini: [redis1] section is what icingadb-web actually reads (IcingaRedis.php)
cat > /etc/icingaweb2/modules/icingadb/redis.ini <<REDISINI
[redis1]
host = 127.0.0.1
port = 6379
REDISINI

cat > /etc/icingaweb2/modules/icingadb/commandtransports.ini <<CMDTRANSPORT
[icinga2]
transport = "api"
host = "localhost"
port = 5665
username = "icingaweb2"
password = "$(awk '/object ApiUser "icingaweb2"/{f=1} f && /password/{gsub(/[" ]/,"",$3); print $3; exit}' /etc/icinga2/conf.d/api-users.conf)"
CMDTRANSPORT

# Fix permissions
chown -R www-data:icingaweb2 /etc/icingaweb2
chmod -R 2770 /etc/icingaweb2
usermod -aG icingaweb2 www-data

# Create or update admin user in IcingaWeb2 DB
ADMIN_HASH="$(php -r "echo password_hash('${ICINGAWEB_ADMIN_PASS}', PASSWORD_DEFAULT);")"
mysql -u "${ICINGAWEB_DB_USER}" -p"${ICINGAWEB_DB_PASS}" "${ICINGAWEB_DB_NAME}" <<SQL
INSERT INTO icingaweb_user (name, active, password_hash)
VALUES ('admin', 1, '${ADMIN_HASH}')
ON DUPLICATE KEY UPDATE password_hash='${ADMIN_HASH}', active=1;
SQL

# ── 9. Apache2 ────────────────────────────────────────────────────────────────
log "Configuring Apache2..."
# Disable all PHP modules first to avoid conflicts (multiple PHP versions cause segfault)
PHP_MOD="$(php -r 'echo "php" . PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "php8.3")"
a2dismod php5.6 php7.0 php7.2 php7.4 php8.0 php8.1 php8.2 php8.3 2>/dev/null || true
a2enmod rewrite "$PHP_MOD" 2>&1 | tee -a "$LOG_FILE" || true

cat > /etc/apache2/conf-available/icingaweb2.conf <<APACHECONF
Alias /icingaweb2 "/usr/share/icingaweb2/public"

<Directory "/usr/share/icingaweb2/public">
    Options SymLinksIfOwnerMatch
    AllowOverride None
    DirectoryIndex index.php

    <IfModule mod_authz_core.c>
        Require all granted
    </IfModule>

    SetEnv ICINGAWEB_CONFIGDIR "/etc/icingaweb2"

    EnableSendfile Off

    <IfModule mod_rewrite.c>
        RewriteEngine on
        RewriteBase /icingaweb2
        RewriteCond %{REQUEST_FILENAME} -s [OR]
        RewriteCond %{REQUEST_FILENAME} -l [OR]
        RewriteCond %{REQUEST_FILENAME} -d
        RewriteRule ^.*$ - [NC,L]
        RewriteRule ^.*$ index.php [NC,L]
    </IfModule>

    <IfModule !mod_rewrite.c>
        php_flag display_startup_errors on
    </IfModule>
</Directory>
APACHECONF

a2enconf icingaweb2
svc enable apache2
svc restart apache2

# ── 10. Copy custom config ────────────────────────────────────────────────────
if [[ -d "${SCRIPT_DIR}/icingaweb2" ]]; then
    log "Copying custom IcingaWeb2 configuration..."
    cp -r "${SCRIPT_DIR}/icingaweb2/"* /etc/icingaweb2/
    chown -R www-data:icingaweb2 /etc/icingaweb2
fi

# Install custom scripts to /opt/icinga-scripts
if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
    log "Installing custom scripts to /opt/icinga-scripts..."
    mkdir -p /opt/icinga-scripts
    cp -r "${SCRIPT_DIR}/scripts/"* /opt/icinga-scripts/
    chmod +x /opt/icinga-scripts/*.sh /opt/icinga-scripts/checks/*.sh 2>/dev/null || true
    # Bootstrap config.env from example if not present (config.env is gitignored)
    if [[ ! -f /opt/icinga-scripts/config.env ]] && [[ -f /opt/icinga-scripts/config.env.example ]]; then
        cp /opt/icinga-scripts/config.env.example /opt/icinga-scripts/config.env
    fi
    # Merge any new variables from config.env.example that are missing in config.env
    if [[ -f /opt/icinga-scripts/config.env ]] && [[ -f /opt/icinga-scripts/config.env.example ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[A-Z_]+= ]] || continue
            varname="${line%%=*}"
            if ! grep -q "^${varname}=" /opt/icinga-scripts/config.env 2>/dev/null; then
                log "Adding missing variable ${varname} to config.env"
                echo "$line" >> /opt/icinga-scripts/config.env
            fi
        done < /opt/icinga-scripts/config.env.example
    fi
    # Bootstrap secrets.env from example if not present (secrets.env is gitignored)
    if [[ ! -f /opt/icinga-scripts/secrets.env ]] && [[ -f /opt/icinga-scripts/secrets.env.example ]]; then
        cp /opt/icinga-scripts/secrets.env.example /opt/icinga-scripts/secrets.env
    fi
    # Merge any new variables from secrets.env.example that are missing in secrets.env
    if [[ -f /opt/icinga-scripts/secrets.env ]] && [[ -f /opt/icinga-scripts/secrets.env.example ]]; then
        while IFS= read -r line; do
            # Only process VAR= lines (skip comments and blanks)
            [[ "$line" =~ ^[A-Z_]+=  ]] || continue
            varname="${line%%=*}"
            if ! grep -q "^${varname}=" /opt/icinga-scripts/secrets.env 2>/dev/null; then
                log "Adding missing variable ${varname} to secrets.env"
                echo "$line" >> /opt/icinga-scripts/secrets.env
            fi
        done < /opt/icinga-scripts/secrets.env.example
    fi
    # Always patch Icinga2 API password into secrets.env (regenerated on every setup run)
    if [[ -f /opt/icinga-scripts/secrets.env ]] && [[ -f /etc/icinga2/conf.d/api-users.conf ]]; then
        log "Patching /opt/icinga-scripts/secrets.env with API credentials..."
        API_PASS=$(awk '/object ApiUser "icinga-scripts"/{f=1} f && /password/{gsub(/[" ]/,"",$3); print $3; exit}' \
            /etc/icinga2/conf.d/api-users.conf)
        if grep -q '^ICINGA2_PASS=' /opt/icinga-scripts/secrets.env 2>/dev/null; then
            sed -i "s|^ICINGA2_PASS=.*|ICINGA2_PASS=\"${API_PASS}\"|" /opt/icinga-scripts/secrets.env
        else
            echo "ICINGA2_PASS=\"${API_PASS}\"" >> /opt/icinga-scripts/secrets.env
        fi
    fi
    chmod 640 /opt/icinga-scripts/secrets.env 2>/dev/null || true
    chmod 640 /opt/icinga-scripts/config.env 2>/dev/null || true

    # Run initial host import from QuestDB (skip if QuestDB not configured)
    QHOST=$(grep '^QUESTDB_HOST=' /opt/icinga-scripts/config.env 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -n "$QHOST" && "$QHOST" != "localhost" ]]; then
        log "Running initial host import from QuestDB (${QHOST})..."
        bash /opt/icinga-scripts/import-hosts-questdb.sh || log "Warning: host import failed — check QuestDB connectivity"
    else
        log "Skipping host import: QUESTDB_HOST not configured in /opt/icinga-scripts/config.env"
    fi
fi

# ── 11. HaloITSM notifications (optional) ────────────────────────────────────
# Enable with: ENABLE_HALO_NOTIFICATIONS=true sudo -E bash setup.sh
ENABLE_HALO_NOTIFICATIONS="${ENABLE_HALO_NOTIFICATIONS:-false}"
if [[ "$ENABLE_HALO_NOTIFICATIONS" == "true" ]]; then
    if [[ -d "${SCRIPT_DIR}/icinga2/zones.d/master" ]]; then
        log "Deploying HaloITSM notification config..."
        mkdir -p /etc/icinga2/zones.d/master
        cp "${SCRIPT_DIR}/icinga2/zones.d/master/"*.conf /etc/icinga2/zones.d/master/
        chown -R root:nagios /etc/icinga2/zones.d/master/ 2>/dev/null || true
        chmod 640 /etc/icinga2/zones.d/master/*.conf
        log "HaloITSM notification config deployed to /etc/icinga2/zones.d/master/"
        log "Remember to set HALO_URL, HALO_USER, HALO_PASS, and ICINGA2_WEB_URL in /opt/icinga-scripts/config.env and secrets.env"
    else
        log "Warning: icinga2/zones.d/master not found in repo — skipping HaloITSM config"
    fi
else
    log "Skipping HaloITSM notification config (set ENABLE_HALO_NOTIFICATIONS=true to enable)"
fi

# ── 12. Go ────────────────────────────────────────────────────────────────────
GO_VERSION="${GO_VERSION:-1.22.5}"
log "Installing Go ${GO_VERSION}..."
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64)  GO_ARCH="amd64" ;;
    arm64)  GO_ARCH="arm64" ;;
    armhf)  GO_ARCH="armv6l" ;;
    *)      die "Unsupported arch for Go: $ARCH" ;;
esac
GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
rm -rf /usr/local/go
tar -C /usr/local -xzf "/tmp/${GO_TAR}"
rm "/tmp/${GO_TAR}"
# Add to system-wide PATH
cat > /etc/profile.d/golang.sh <<'GOPATH'
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
GOPATH
export PATH=$PATH:/usr/local/go/bin
log "Go $(/usr/local/go/bin/go version) installed"

# ── 13. Final restart ─────────────────────────────────────────────────────────
log "Restarting all services..."
svc restart redis-server icingadb icinga2 apache2

# ── 14. Summary ───────────────────────────────────────────────────────────────
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
IP="$(hostname -I | awk '{print $1}')"

log "Setup complete!"
cat <<SUMMARY

═══════════════════════════════════════════════
  Icinga2 Monolith - Setup Complete
═══════════════════════════════════════════════

  Web UI:      http://${IP}/icingaweb2
               http://${HOSTNAME}/icingaweb2

  Login:       admin / ${ICINGAWEB_ADMIN_PASS}

  All credentials saved to:
               /etc/icinga-setup/credentials.env

  NOTE: If using QuestDB host import, ensure
  QUESTDB_USER and QUESTDB_PASS are set in:
               /opt/icinga-scripts/secrets.env

  Go:          $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')

  Services:
    icinga2     $(systemctl is-active icinga2)
    icingadb    $(systemctl is-active icingadb)
    redis       $(systemctl is-active redis-server)
    mariadb     $(systemctl is-active mariadb)
    apache2     $(systemctl is-active apache2)

═══════════════════════════════════════════════
SUMMARY
