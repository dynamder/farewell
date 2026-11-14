#!/usr/bin/env bash
export PATH="$HOME/.cargo/bin:$PATH"
for t in notcurses-demo timg img2sixel convert agg asciinema; do printf '%-16s %s\n' "$t" "$(command -v "$t" || echo MISSING)"; done
echo "== agg version =="; agg --version 2>&1 | head -2
echo "== asciinema =="; asciinema --version 2>&1 | head -2
echo "== notcurses demo help =="; notcurses-demo --help 2>&1 | head -12
