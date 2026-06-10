#!/bin/bash

# ============================================
#  PlayAroundIT Lab - VM Disk Usage Summary
#  Run from the vagrant/ directory
# ============================================

VAGRANT_DIR="$(cd "$(dirname "$0")/../vagrant" && pwd)"

if [ ! -f "$VAGRANT_DIR/Vagrantfile" ]; then
  echo "ERROR: Vagrantfile not found at $VAGRANT_DIR"
  exit 1
fi

cd "$VAGRANT_DIR"

echo ""
echo "============================================"
echo "  Observability Lab - VM Disk Usage"
echo "============================================"
printf "  %-14s %-10s %-10s %-10s %-8s\n" \
  "HOSTNAME" "SIZE" "USED" "AVAIL" "USE%"
echo "  --------------------------------------------------"

# Dynamically discover all running VMs
VMS=$(vagrant status --machine-readable 2>/dev/null \
  | grep ",state,running" \
  | awk -F',' '{print $2}')

for VM in $VMS; do
  DISK=$(vagrant ssh "$VM" -c \
    "df -h / | tail -1 | awk '{print \$2, \$3, \$4, \$5}'" \
    2>/dev/null | tr -d '\r')

  SIZE=$(echo $DISK | awk '{print $1}')
  USED=$(echo $DISK | awk '{print $2}')
  AVAIL=$(echo $DISK | awk '{print $3}')
  PCT=$(echo $DISK | awk '{print $4}')

  printf "  %-14s %-10s %-10s %-10s %-8s\n" \
    "$VM" "$SIZE" "$USED" "$AVAIL" "$PCT"
done

echo "  --------------------------------------------------"
echo ""