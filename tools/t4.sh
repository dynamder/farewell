#!/usr/bin/env bash
export PATH="/home/dynamder/.cargo/bin:$PATH"
D=/mnt/d/farewell/demos
echo "== fonts =="; fc-list 2>/dev/null | grep -icE "dejavu|jetbrains|fira|noto" ; fc-list 2>/dev/null | grep -iE "dejavusansmono|jetbrains" | head -3
echo "== portrait =="
curl -sL -m 40 -A "Mozilla/5.0" -o "$D/mona.jpg" \
  "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ec/Mona_Lisa%2C_by_Leonardo_da_Vinci%2C_from_C2RMF_retouched.jpg/640px-Mona_Lisa%2C_by_Leonardo_da_Vinci%2C_from_C2RMF_retouched.jpg"
identify "$D/mona.jpg" 2>&1 | head -2
echo "== compile VinZ =="
cd /mnt/d/farewell/refs/VinZ && gcc -O2 -o /tmp/vinz vinz.c -lm 2>&1 | tail -5 && echo "vinz built: $(ls -l /tmp/vinz | awk '{print $5}')"
echo "== compile asciitracing =="
cd /mnt/d/farewell/refs/asciitracing && ls *.cc && g++ -O2 -std=c++17 -o /tmp/asciitrace *.cc 2>&1 | tail -5 && echo "asciitrace built"
