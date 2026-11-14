#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
tmux kill-server 2>/dev/null
rm -f /tmp/nc.log
tmux new-session -d -s d -x 140 -y 40 "notcurses-demo k 2>/tmp/nc.log"
sleep 14
echo "== pane lines (non-empty) =="; tmux capture-pane -p -t d | grep -c . 
echo "== sample =="; tmux capture-pane -p -t d | grep . | head -6
echo "== log grep =="; grep -iE "init|blitter|sixel|kitty|query term|timeout|fail" /tmp/nc.log | tail -12
tmux kill-server 2>/dev/null
