#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos
mkdir -p "$D"
name="$1"; letter="$2"; secs="${3:-10}"
asciinema rec --overwrite -c "stty cols 140 rows 40; timeout $secs notcurses-demo -d 1.0 $letter" "$D/$name.cast" 2>&1 | tail -2
ls -l "$D/$name.cast"
cd "$D" && agg --font-size 14 --speed 1.0 "$name.cast" "$name.gif" 2>&1 | tail -2
ls -l "$name.gif" 2>/dev/null
