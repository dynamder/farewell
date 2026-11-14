#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
D=/mnt/d/farewell/demos
python3 /mnt/d/farewell/tools/castify.py "$D/chafa.cast" 110 38 "$D/chafa.txt"
cd "$D" && agg --font-size 13 --speed 0.5 chafa.cast chafa.gif 2>&1 | tail -1
convert gif:"$D/chafa.gif[0]" "$D/chafa_still.png" 2>&1 | tail -1
ls -l "$D"/chafa.* "$D"/chafa_still.png 2>/dev/null
