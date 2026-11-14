#!/usr/bin/env bash
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>&1 | tail -3
apt-get install -y -qq notcurses-bin timg libsixel-bin imagemagick 2>&1 | tail -5
echo "=== installed ==="
for t in notcurses-demo timg img2sixel convert; do printf '%-16s %s\n' "$t" "$(command -v "$t" || echo -)"; done
ls -l /home/dynamder/.cargo/bin/ 2>/dev/null
