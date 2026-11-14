#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; B=/mnt/d/farewell/bin
bash /mnt/d/farewell/tools/grab.sh vinz 120 40 16 0.2 "$B/vinz"
echo "== sixel demo =="
img2sixel -w 640 "$D/rose.png" > "$D/rose.six" 2>/dev/null
echo "sixel bytes: $(stat -c%s "$D/rose.six")"
sixel2png "$D/rose.six" "$D/rose_sixel_decoded.png" 2>&1 | tail -2
identify "$D/rose_sixel_decoded.png" 2>&1 | head -1
echo "== asciitracing compile =="
cd /mnt/d/farewell/refs/asciitracing
g++ -O2 -std=c++17 -o "$B/st" st.cc 2>&1 | tail -3; ls -l "$B/st" 2>/dev/null | awk '{print $5}'
g++ -O2 -std=c++17 -o "$B/rt" render.cc rt.cc 2>&1 | tail -2
ls "$B"
