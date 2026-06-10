#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
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
    fail "Please run this script as root"
  fi
}

#### MAIN ####
require_root

log "Updating packages..."
apt-get update -y
apt-get upgrade -y

log "Installing base dependencies..."
apt-get install -y \
  wget \
  curl \
  apt-transport-https \
  gnupg \
  ca-certificates \
  openssl \
  git \
  jq \
  unzip \
  python3-pip

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Verifying NTP sync..."
timedatectl show --property=NTPSynchronized

log "Base configuration complete."
log "Ready for Prometheus, Grafana, OTel Collector, and Jaeger installation."