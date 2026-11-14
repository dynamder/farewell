#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
for t in agg asciinema; do printf '%-12s %s\n' "$t" "$(command -v "$t" || echo MISSING)"; done
agg --version 2>&1 | head -1
asciinema --version 2>&1 | head -1
mkdir -p /mnt/d/farewell/demos
asciinema rec --overwrite -c "printf 'hello \033[1;32mworld\033[0m\n'; sleep 0.6" /mnt/d/farewell/demos/smoke.cast 2>&1 | tail -2
cd /mnt/d/farewell/demos && agg --font-size 20 smoke.cast smoke.gif 2>&1 | tail -3
ls -l /mnt/d/farewell/demos/
