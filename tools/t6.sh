#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
export TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 LC_ALL=C.UTF-8
D=/mnt/d/farewell/demos; B=/mnt/d/farewell/bin
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
echo "== VinZ in tmux =="
tmux kill-server 2>/dev/null
tmux new-session -d -s v -x 120 -y 40 "$B/vinz"
sleep 2
echo "non-empty lines: $(tmux capture-pane -p -t v | grep -c .)"
tmux capture-pane -p -t v | head -3
tmux kill-server 2>/dev/null
echo "== rose image =="
convert rose: -resize 900x600 "$D/rose.png" && identify "$D/rose.png"
for v in "full:full:" "256:256:--dither ordered" ; do :; done
chafa -f symbols -c full -s 100x34 "$D/rose.png" > "$D/rose_truecolor.txt"
chafa -f symbols -c 256 --dither ordered -s 100x34 "$D/rose.png" > "$D/rose_256.txt"
chafa -f symbols --symbols ascii -c 16 -s 100x34 "$D/rose.png" > "$D/rose_ascii.txt"
ls -l "$D"/rose_*.txt
command -v sixel2png img2sixel
