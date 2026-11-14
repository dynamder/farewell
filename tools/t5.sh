#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; B=/mnt/d/farewell/bin; mkdir -p "$D" "$B"
cd /mnt/d/farewell/refs/VinZ && gcc -O2 -o "$B/vinz" vinz.c -lm 2>&1 | tail -3
echo "built: $(ls -l $B/vinz | awk '{print $5}')"
echo "== direct run 2s to file =="
timeout -s KILL 2 "$B/vinz" > /tmp/v.out 2>/tmp/v.err </dev/null; echo "rc=$?"
echo "size=$(stat -c%s /tmp/v.out)"; head -c 100 /tmp/v.out | cat -v; echo; tail -2 /tmp/v.err
echo "== picsum test =="
curl -s -o /dev/null -w "%{http_code}\n" -m 15 "https://picsum.photos/800/600" || echo curlfail
