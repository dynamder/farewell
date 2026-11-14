#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; B=/mnt/d/farewell/bin
mkdir -p "$D/frames_vinz3d"; rm -f "$D/frames_vinz3d"/*.txt
tmux kill-server 2>/dev/null
tmux new-session -d -s g -x 120 -y 40 "$B/vinz"
sleep 1.2
tmux send-keys -t g T          # toggle 3D raymarching
sleep 1.5
for i in $(seq 1 14); do
  sleep 0.18
  tmux capture-pane -e -p -t g > "$D/frames_vinz3d/$(printf %03d $i).txt"
done
tmux kill-server 2>/dev/null
echo "captured $(ls $D/frames_vinz3d | wc -l) frames, last $(stat -c%s $D/frames_vinz3d/$(ls $D/frames_vinz3d | tail -1)) bytes"
grep -o "3D (NEW): [A-Z]*" "$D/frames_vinz3d/014.txt" | head -1
