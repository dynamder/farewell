#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
echo "== direct run, stdout to file (2s) =="
timeout -s KILL 2 /tmp/vinz > /tmp/v.out 2>/tmp/v.err </dev/null; echo "rc=$?"
echo "size=$(stat -c%s /tmp/v.out 2>/dev/null) err=$(stat -c%s /tmp/v.err 2>/dev/null)"
head -c 120 /tmp/v.out | cat -v; echo
tail -3 /tmp/v.err
echo "== run in tmux, capture =="
tmux kill-server 2>/dev/null
tmux new-session -d -s v -x 120 -y 40 "/tmp/vinz > /tmp/v2.out 2>/tmp/v2.err"
sleep 2
echo "pane non-empty lines: $(tmux capture-pane -p -t v | grep -c .)"
tmux capture-pane -p -t v | head -5
echo "out size=$(stat -c%s /tmp/v2.out 2>/dev/null)"
tail -3 /tmp/v2.err
tmux kill-server 2>/dev/null
