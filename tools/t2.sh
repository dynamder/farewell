#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos
echo "== notcurses-info in tmux =="
tmux kill-server 2>/dev/null
tmux new-session -d -s i -x 120 -y 40 "notcurses-info > $D/ncinfo.txt 2>&1; echo done > /tmp/i.done"
sleep 8
cat /tmp/i.done 2>/dev/null || echo "still running"
head -12 "$D/ncinfo.txt" 2>/dev/null
tmux kill-server 2>/dev/null
echo "== chafa =="
convert -size 900x600 plasma:fractal "$D/plasma.png" 2>&1 | tail -2
chafa -f symbols -c full -s 110x38 "$D/plasma.png" > "$D/chafa.txt" 2>"$D/chafa.err"
echo "chafa bytes: $(stat -c%s "$D/chafa.txt")"; tail -2 "$D/chafa.err"
head -c 300 "$D/chafa.txt" | cat -v | head -3
