#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
SPLUNK_VERSION="10.4.0"
SPLUNK_BUILD="f798d4d49089"
SPLUNK_PACKAGE="splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD}-linux-amd64.tgz"
SPLUNK_URL="https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/${SPLUNK_PACKAGE}"

SPLUNK_HOME="/opt/splunk"
SPLUNK_USER="splunk"
TIMEZONE="Europe/Berlin"

ADMIN_USER="admin"
ADMIN_PWD="${ADMIN_PWD:-adminuser123!}"

#### FUNCTIONS ####
log() {
  echo "[INFO] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Please run this script as root, e.g. sudo ./splunk_install.sh"
  fi
}

#### MAIN ####
require_root

log "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y wget ca-certificates tar

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Creating Splunk user if needed..."
if ! id "$SPLUNK_USER" &>/dev/null; then
  useradd --system --create-home --shell /bin/bash "$SPLUNK_USER"
fi

log "Checking for local Splunk package..."
if [[ -f "/opt/packages/${SPLUNK_PACKAGE}" ]]; then
  log "Local package found — copying instead of downloading..."
  cp "/opt/packages/${SPLUNK_PACKAGE}" "/opt/${SPLUNK_PACKAGE}"
elif [[ ! -f "/opt/${SPLUNK_PACKAGE}" ]]; then
  log "Downloading Splunk Enterprise ${SPLUNK_VERSION}..."
  wget -q --show-progress --progress=bar:force:noscroll \
    -O "/opt/${SPLUNK_PACKAGE}" "$SPLUNK_URL"
else
  log "Package already exists, skipping."
fi

log "Extracting Splunk to /opt..."
if [[ ! -d "$SPLUNK_HOME" ]]; then
  tar -xzf "/opt/${SPLUNK_PACKAGE}" -C /opt
else
  log "${SPLUNK_HOME} already exists, skipping extraction."
fi

log "Setting ownership..."
chown -R "${SPLUNK_USER}:${SPLUNK_USER}" "$SPLUNK_HOME"

log "Creating user-seed.conf for initial admin password..."
mkdir -p "$SPLUNK_HOME/etc/system/local"
cat > "$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = ${ADMIN_USER}
PASSWORD = ${ADMIN_PWD}
EOF

chown "${SPLUNK_USER}:${SPLUNK_USER}" \
  "$SPLUNK_HOME/etc/system/local/user-seed.conf"
chmod 600 "$SPLUNK_HOME/etc/system/local/user-seed.conf"

log "Accepting license and enabling Splunk boot-start via systemd..."
"$SPLUNK_HOME/bin/splunk" enable boot-start \
  -user "$SPLUNK_USER" \
  -systemd-managed 1 \
  --accept-license \
  --answer-yes \
  --no-prompt

log "Adding Splunk CLI alias..."
cat > /etc/profile.d/splunk-alias.sh <<EOF
alias splunk='sudo ${SPLUNK_HOME}/bin/splunk'
EOF
chmod 644 /etc/profile.d/splunk-alias.sh

log "Splunk ${SPLUNK_VERSION} installed and configured."
log "Splunk secret and startup are intentionally deferred for manual configuration."
log "When ready: systemctl start Splunkd"