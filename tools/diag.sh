#!/usr/bin/env bash
echo "== locks =="; for f in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock; do [ -e "$f" ] && echo "$f exists"; done
echo "== procs =="; ps -eo pid,etime,comm | grep -Ei "apt|dpkg|tmux|notcurses|asciinema|agg" | grep -v grep
echo "== tmux? =="; command -v tmux || echo missing
echo "== demos =="; ls -l /mnt/d/farewell/demos/
