#!/usr/bin/env bash
export PATH="$HOME/.cargo/bin:$PATH"
for t in notcurses-demo timg img2sixel convert agg asciinema; do printf '%-16s %s\n' "$t" "$(command -v "$t" || echo MISSING)"; done
echo "== agg =="; agg --version 2>&1 | head -1
echo "== asciinema =="; asciinema --version 2>&1 | head -1
echo "== smoke cast =="
mkdir -p /mnt/d/farewell/demos
asciinema rec --overwrite -c "printf 'hello \033[1;32mworld\033[0m\n'; sleep 0.6" /mnt/d/farewell/demos/smoke.cast 2>&1 | tail -2
ls -l /mnt/d/farewell/demos/
echo "== smoke gif =="
cd /mnt/d/farewell/demos && agg --font-size 16 smoke.cast smoke.gif 2>&1 | tail -3; ls -l smoke.gif 2>/dev/null
