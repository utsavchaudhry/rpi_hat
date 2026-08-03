#!/usr/bin/env bash
# Run on the Jetson Thor. Verifies it's getting a DHCP lease from the Pi
# router (10.42.0.0/24) and can route out to the internet through it.
set -euo pipefail

GATEWAY="10.42.0.1"

IFACE=$(nmcli -t -f DEVICE,TYPE,STATE device status \
  | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')

if [[ -z "${IFACE:-}" ]]; then
  echo "No connected ethernet device found. Check the cable to the Pi and 'nmcli device status'." >&2
  exit 1
fi

echo "Using ethernet device: $IFACE"
ADDR=$(ip -4 -o addr show "$IFACE" | awk '{print $4}')
echo "Address: ${ADDR:-none}"

if [[ "$ADDR" != 10.42.0.* ]]; then
  echo "WARNING: address is not in the expected 10.42.0.0/24 range from the Pi." >&2
fi

echo "--- Pinging Pi gateway ($GATEWAY) ---"
ping -c 3 "$GATEWAY"

echo "--- Pinging internet (8.8.8.8) through the Pi ---"
ping -c 3 8.8.8.8

echo "All checks passed: Thor is routed through the Pi."
