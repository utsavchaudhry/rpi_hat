#!/usr/bin/env bash
# Run on the Pi. Configures eth0 to NAT/DHCP-share the Pi's upstream
# connection (WiFi) to whatever's plugged into eth0 (the Jetson Thor).
#
# Idempotent and safe to re-run after a fresh Pi flash — the netplan
# connection UUID will differ each time, this script re-discovers it
# rather than hardcoding one.
set -euo pipefail

CONN_NAME="netplan-eth0"

if ! nmcli -g connection.uuid connection show "$CONN_NAME" >/dev/null 2>&1; then
  echo "No '$CONN_NAME' connection found. Run 'nmcli connection show' and check the eth0 profile name." >&2
  exit 1
fi

UUID=$(nmcli -g connection.uuid connection show "$CONN_NAME")
NETPLAN_FILE="/etc/netplan/90-NM-${UUID}.yaml"

if [[ ! -f "$NETPLAN_FILE" ]]; then
  echo "Expected netplan file not found: $NETPLAN_FILE" >&2
  echo "Check 'sudo ls /etc/netplan/' for the actual generated filename and adjust." >&2
  exit 1
fi

CURRENT_METHOD=$(nmcli -g ipv4.method connection show "$CONN_NAME")
if [[ "$CURRENT_METHOD" == "shared" ]]; then
  echo "eth0 is already in shared mode. Skipping netplan edit."
else
  echo "Setting ipv4.method=shared in $NETPLAN_FILE"
  if sudo grep -q 'ipv4\.method' "$NETPLAN_FILE"; then
    sudo sed -i 's/ipv4\.method:.*/ipv4.method: "shared"/' "$NETPLAN_FILE"
  else
    sudo sed -i '/proxy\._: ""/a\          ipv4.method: "shared"' "$NETPLAN_FILE"
  fi
  sudo chmod 600 "$NETPLAN_FILE"
  sudo netplan apply
  sleep 3
fi

echo "--- ipv4.method (expect: shared) ---"
nmcli -g ipv4.method connection show "$CONN_NAME"
echo "--- device status (expect: eth0 connected) ---"
nmcli device status
echo "--- eth0 address (expect: 10.42.0.1/24) ---"
ip -4 addr show eth0
echo "--- IP forwarding (expect: 1) ---"
sysctl net.ipv4.ip_forward
echo "--- NAT rule ---"
sudo iptables -t nat -L -n -v | grep -i MASQUERADE \
  || echo "No MASQUERADE rule found yet — give it a few seconds after apply and re-check."
