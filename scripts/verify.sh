#!/usr/bin/env bash
set -euo pipefail
command -v dig >/dev/null || { echo "Install dig (Ubuntu: dnsutils; macOS: provided by OS)." >&2; exit 1; }
internal=$(dig @127.0.0.1 -p 15353 www.example.test A +short)
external=$(dig @127.0.0.1 -p 15354 www.example.test A +short)
[[ "$internal" == 192.0.2.20 && "$external" == 198.51.100.20 ]]
dig @127.0.0.1 -p 15354 vault.example.test A | grep -q 'status: NXDOMAIN'
dig @127.0.0.1 -p 15353 www.example.test A +tcp +short | grep -qx 192.0.2.20
echo "Verified different internal/external answers, private name absent externally, TCP DNS works."
