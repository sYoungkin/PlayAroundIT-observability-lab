#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
ELASTIC_VERSION="9.x"
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="${ADMIN_PWD:-adminuser123!}"
TIMEZONE="Europe/Berlin"

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
    fail "Please run this script as root, e.g. sudo ./elastic_install.sh"
  fi
}

wait_for_elasticsearch() {
  log "Waiting for Elasticsearch to become available..."
  local retries=30
  local wait=10
  until curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
    -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
    https://localhost:9200 >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ $retries -eq 0 ]]; then
      fail "Elasticsearch did not become available in time."
    fi
    log "Elasticsearch not ready yet. Retrying in ${wait}s... (${retries} attempts left)"
    sleep $wait
  done
  log "Elasticsearch is up."
}

#### MAIN ####
require_root

log "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y wget curl apt-transport-https gnupg ca-certificates openssl

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Adding Elastic GPG key..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

log "Adding Elastic ${ELASTIC_VERSION} APT repository..."
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/${ELASTIC_VERSION}/apt stable main" \
  | tee /etc/apt/sources.list.d/elastic-${ELASTIC_VERSION}.list

log "Updating package index..."
apt-get update -y

log "Installing Elasticsearch..."
apt-get install -y elasticsearch

log "Installing Kibana..."
apt-get install -y kibana

log "Granting Kibana access to Elasticsearch certificates..."
usermod -aG elasticsearch kibana

log "Installing Ansible and pip3..."
apt-get install -y ansible python3-pip

log "Upgrading Ansible to latest version..."
pip3 install --upgrade ansible

log "Ansible version: $(ansible --version | head -1)"

log "Creating Ansible workspace..."
mkdir -p /etc/ansible

log "Setting elastic superuser password via keystore bootstrap..."
ES_KEYSTORE="/usr/share/elasticsearch/bin/elasticsearch-keystore"
echo "$ELASTIC_PASSWORD" | $ES_KEYSTORE add -f "bootstrap.password"

log "Enabling and starting Elasticsearch..."
systemctl daemon-reload
systemctl enable elasticsearch.service
systemctl start elasticsearch.service

wait_for_elasticsearch

log "Resetting kibana_system password via API..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  https://localhost:9200/_security/user/kibana_system/_password \
  -d "{\"password\": \"${ELASTIC_PASSWORD}\"}")

if [[ "$HTTP_CODE" != "200" ]]; then
  fail "Failed to set kibana_system password via API (HTTP ${HTTP_CODE})"
fi

log "kibana_system password set successfully."

log "Configuring Kibana..."
KIBANA_CONF="/etc/kibana/kibana.yml"

sed -i 's/#server.host: "localhost"/server.host: "0.0.0.0"/' "$KIBANA_CONF" \
  || echo 'server.host: "0.0.0.0"' >> "$KIBANA_CONF"

cat >> "$KIBANA_CONF" <<EOF

# Elasticsearch connection - configured by elastic_install.sh
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ELASTIC_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["/etc/elasticsearch/certs/http_ca.crt"]
elasticsearch.ssl.verificationMode: certificate
EOF

log "Adding encryption key to kibana.yml..."
ENCRYPTION_KEY=$(openssl rand -hex 32)
cat >> "$KIBANA_CONF" <<EOF

# Saved objects encryption key
xpack.encryptedSavedObjects.encryptionKey: "${ENCRYPTION_KEY}"
EOF

log "Enabling and starting Kibana..."
systemctl enable kibana.service
systemctl start kibana.service

VM_IP=$(hostname -I | awk '{print $1}')

log "Elasticsearch and Kibana installation complete."
log ""
log "Elasticsearch: https://${VM_IP}:9200"
log "Kibana:        http://${VM_IP}:5601"
log "Username:      ${ELASTIC_USER}"
log "Password:      ${ELASTIC_PASSWORD}"