#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
tmux kill-server 2>/dev/null
rm -f /tmp/nc.log /tmp/nc.done
tmux new-session -d -s d -x 140 -y 40 "notcurses-demo -l 7 k >/tmp/nc.out 2>/tmp/nc.log; echo EXIT=\$? > /tmp/nc.done"
sleep 6
echo "== pane =="; tmux capture-pane -p -t d | head -20
echo "== done? =="; cat /tmp/nc.done 2>/dev/null || echo running
echo "== log tail =="; tail -25 /tmp/nc.log 2>/dev/null
tmux kill-server 2>/dev/null
