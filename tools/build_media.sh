#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; B=/mnt/d/farewell/bin
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
frames_to_cast() { # name cols rows delay
  local n=$1 c=$2 r=$3 d=$4
  python3 - "$n" "$c" "$r" "$d" <<'PY'
import glob, json, sys, time
n, c, r, d = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
files = sorted(glob.glob(f"/mnt/d/farewell/demos/frames_{n}/*.txt"))
with open(f"/mnt/d/farewell/demos/{n}.cast", "w", encoding="utf8") as f:
    f.write(json.dumps({"version": 2, "width": c, "height": r, "timestamp": int(time.time())}) + "\n")
    t = 0.0
    for p in files:
        f.write(json.dumps([round(t, 3), "o", "\x1b[H\x1b[2J" + open(p, encoding="utf8", errors="replace").read()]) + "\n")
        t += d
print("cast frames:", len(files))
PY
  cd "$D" && agg --font-file "$FONT" --font-size 13 --speed 1.0 "$n.cast" "$n.gif" >/dev/null 2>&1
  convert gif:"$n.gif" -coalesce -delete 1--1 "$n.png" 2>/dev/null
  echo "$n.gif $(stat -c%s $n.gif 2>/dev/null) bytes"
}
frames_to_cast vinz 120 40 0.12
bash /mnt/d/farewell/tools/grab.sh st 110 36 10 0.2 "$B/st"
frames_to_cast st 110 36 0.15
for v in truecolor 256 ascii; do
  python3 /mnt/d/farewell/tools/castify.py "$D/chafa_$v.cast" 100 34 "$D/rose_$v.txt" >/dev/null
  cd "$D" && agg --font-file "$FONT" --font-size 13 "$D/chafa_$v.cast" "$D/chafa_$v.gif" >/dev/null 2>&1
  convert gif:"$D/chafa_$v.gif" -coalesce -delete 1--1 "$D/chafa_$v.png" 2>/dev/null
done
ls -l "$D"/*.png "$D"/*.gif 2>/dev/null | awk '{print $5, $9}'
