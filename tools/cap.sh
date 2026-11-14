#!/usr/bin/env bash
# usage: cap.sh <name> <seconds> <frames> <cols> <rows> -- <command...>
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
name=$1; secs=$2; frames=$3; cols=$4; rows=$5; shift 5
[ "$1" = "--" ] && shift
cmd="$*"
D=/mnt/d/farewell/demos; mkdir -p "$D"
tmux kill-server 2>/dev/null
tmux new-session -d -s cap -x "$cols" -y "$rows" "$cmd"
python3 - "$name" "$secs" "$frames" "$cols" "$rows" <<'PY'
import json, subprocess, sys, time
name, secs, frames, cols, rows = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
path = f"/mnt/d/farewell/demos/{name}.cast"
with open(path, "w", encoding="utf8") as out:
    out.write(json.dumps({"version": 2, "width": cols, "height": rows, "timestamp": int(time.time())}) + "\n")
    t, step = 0.0, secs / frames
    for _ in range(frames):
        time.sleep(step)
        p = subprocess.run(["tmux", "capture-pane", "-e", "-p", "-t", "cap"], capture_output=True, text=True)
        out.write(json.dumps([round(t, 3), "o", "\x1b[H\x1b[2J" + p.stdout]) + "\n")
        t += step
print("frames:", frames, "size:", len(open(path, encoding="utf8").read()))
PY
tmux kill-server 2>/dev/null
cd "$D" && agg --font-size 14 --speed 1.0 "$name.cast" "$name.gif" 2>&1 | tail -2
ls -l "$D/$name.cast" "$D/$name.gif" 2>/dev/null
