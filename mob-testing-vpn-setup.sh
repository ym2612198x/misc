#!/usr/bin/env bash
# Mobile traffic interception setup
# iOS device → OpenVPN (tun1) → Burp on 8090 → ctrl testing VPN (tun0) → internet
#
# Usage: ./mob-testing-setup.sh <path-to-ctrl-vpn.ovpn>
#
# Prerequisites:
#   - Burp Suite running with proxy listener on 0.0.0.0:8090, invisible proxying ON
#   - Run as a user with sudo access (not root)

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path-to-ctrl-vpn.ovpn>"
    exit 1
fi

CTRL_VPN_OVPN="$1"

if [[ ! -f "$CTRL_VPN_OVPN" ]]; then
    echo "Error: ovpn file not found: $CTRL_VPN_OVPN"
    exit 1
fi

VPN_SUBNET="10.9.0.0/24"
VPN_PORT="1193"
BURP_PORT="8090"

# ─────────────────────────────────────────────
# STEP 1: FRESH INSTALL (skipped if already installed)
# ─────────────────────────────────────────────

if [[ ! -f /etc/openvpn/server/server.conf ]]; then
    sudo apt install -y openvpn

    cd /tmp
    curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
    chmod +x openvpn-install.sh

    sudo ./openvpn-install.sh install \
      --endpoint "$(hostname -I | awk '{print $1}')" \
      --ip "$(hostname -I | awk '{print $1}')" \
      --client mob-testing \
      --port "$VPN_PORT" \
      --subnet-ipv4 "10.9.0.0"

    # Use tun1 — tun0 is reserved for the ctrl testing VPN
    sudo sed -i 's/^dev tun$/dev tun1/' /etc/openvpn/server/server.conf

    # Disable the old Debian openvpn service so it doesn't conflict
    sudo systemctl disable --now openvpn@server.service 2>/dev/null || true

    sudo systemctl enable openvpn-server@server.service
else
    echo "OpenVPN already installed, skipping fresh install"
fi

# ─────────────────────────────────────────────
# STEP 2: CONNECT CTRL TESTING VPN
# ─────────────────────────────────────────────

sudo openvpn --daemon --config "$CTRL_VPN_OVPN"
echo "Waiting for tun0..."
until ip link show tun0 &>/dev/null; do sleep 1; done
echo "tun0 is up"

# ─────────────────────────────────────────────
# STEP 3: IP FORWARDING
# ─────────────────────────────────────────────

sudo sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf \
  || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# ─────────────────────────────────────────────
# STEP 4: IPTABLES (flush first so re-runs are clean)
# ─────────────────────────────────────────────

sudo iptables --flush
sudo iptables -t nat --flush

# NAT iOS subnet out via ctrl testing VPN
sudo iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o tun0 -j MASQUERADE

# Redirect iOS web traffic to Burp (transparent, invisible proxying)
for port in 80 443 8080 8443 8000 8888 81 3000 5000 9443; do
    sudo iptables -t nat -A PREROUTING -i tun1 -p tcp --dport "$port" -j REDIRECT --to-ports "$BURP_PORT"
done

# Block QUIC (UDP/443) — forces browsers onto TCP HTTPS so Burp can intercept
sudo iptables -I FORWARD 1 -i tun1 -o tun0 -p udp --dport 443 -j REJECT
sudo iptables -I FORWARD 1 -i tun0 -o tun1 -p udp --sport 443 -j REJECT

# ─────────────────────────────────────────────
# STEP 5: START OPENVPN SERVER
# ─────────────────────────────────────────────

sudo systemctl restart openvpn-server@server.service

# ─────────────────────────────────────────────
# STEP 6: VERIFY
# ─────────────────────────────────────────────

echo ""
echo "=== OpenVPN server ==="
sudo systemctl is-active openvpn-server@server.service

echo ""
echo "=== Interfaces ==="
ip -br addr show tun0 tun1

echo ""
echo "=== Burp proxy check ==="
if ss -tlnp | grep -q "\*:${BURP_PORT}"; then
    echo "  [OK] Burp is listening on all interfaces on port ${BURP_PORT}"
elif ss -tlnp | grep -q ":${BURP_PORT}"; then
    echo "  [WARN] Burp is running on port ${BURP_PORT} but NOT on all interfaces — change listener to 0.0.0.0 in Burp"
else
    echo "  [FAIL] Nothing is listening on port ${BURP_PORT} — start Burp and configure the proxy listener"
fi
echo "  NOTE: invisible proxying cannot be verified from CLI — confirm it is ON in Burp > Proxy > Listener settings"

echo ""
echo "=== Checklist ==="
echo "  [ ] Burp CA cert installed on iOS — Safari > http://$(hostname -I | awk '{print $1}'):${BURP_PORT} > CA Certificate"
echo "  [ ] Burp intercept is OFF (or you will be forwarding requests manually)"
echo "  [ ] iOS client config: $(ls /home/tom/mob-testing*.ovpn 2>/dev/null || echo 'run openvpn-install.sh to generate a client')"
