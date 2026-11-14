#!/usr/bin/env bash
echo "== tools =="
for t in notcurses-demo timg img2sixel agg cargo gcc g++ ffmpeg convert magick viu chafa asciinema python3; do
  printf '%-16s %s\n' "$t" "$(command -v "$t" || echo -)"
done
echo "== distro =="
. /etc/os-release; echo "$PRETTY_NAME"
echo "== root =="
wsl.exe -d Ubuntu -u root -e id -un 2>/dev/null || echo no-root
echo "== apt cache =="
apt-cache policy notcurses-bin timg libsixel-bin 2>/dev/null | grep -E "^(notcurses|timg|libsixel)|Candidate" | head -10
