#!/usr/bin/env bash
# grab.sh <name> <cols> <rows> <frames> <interval> <cmd...>
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
name=$1; cols=$2; rows=$3; frames=$4; iv=$5; shift 5
D=/mnt/d/farewell/demos; mkdir -p "$D/frames_$name"
rm -f "$D/frames_$name"/*.txt
tmux kill-server 2>/dev/null
tmux new-session -d -s g -x "$cols" -y "$rows" "$*"
for i in $(seq 1 "$frames"); do
  sleep "$iv"
  tmux capture-pane -e -p -t g > "$D/frames_$name/$(printf %03d $i).txt" 2>/dev/null
done
tmux kill-server 2>/dev/null
echo "captured: $(ls "$D/frames_$name" | wc -l) frames, last size $(stat -c%s "$D/frames_$name/$(ls "$D/frames_$name" | tail -1)")"
