#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; mkdir -p "$D"
command -v tmux >/dev/null || apt-get install -y -qq tmux
echo "tmux: $(command -v tmux)"
name="$1"; spec="$2"; secs="${3:-8}"
timeout -s KILL 30 asciinema rec --overwrite -c \
  "tmux -u new-session -x 140 -y 40 'timeout -s KILL $secs notcurses-demo $spec'" \
  "$D/$name.cast" 2>&1 | tail -2
echo "rec_exit=$?"
ls -l "$D/$name.cast"
