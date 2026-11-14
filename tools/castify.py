"""把一段 ANSI 文本（或若干快照）合成 asciinema v2 cast。"""
import json, sys, time

def make(path, texts, cols, rows, delay=0.6):
    with open(path, "w", encoding="utf8") as f:
        f.write(json.dumps({"version": 2, "width": cols, "height": rows,
                            "timestamp": int(time.time())}) + "\n")
        t = 0.0
        for txt in texts:
            f.write(json.dumps([round(t, 3), "o", "\x1b[H\x1b[2J" + txt]) + "\n")
            t += delay

if __name__ == "__main__":
    out, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    texts = [open(p, encoding="utf8", errors="replace").read() for p in sys.argv[4:]]
    make(out, texts, cols, rows)
    print("cast:", out, "frames:", len(texts))
