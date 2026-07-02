#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Wait for the old instance to actually exit (not a fixed sleep) — the new
# instance refuses to start while another Ampere process is still running.
pkill -x Ampere 2>/dev/null || true
for _ in $(seq 1 80); do
    pgrep -x Ampere >/dev/null 2>&1 || break
    sleep 0.1
done

swift build -c debug 2>&1 && .build/debug/Ampere
