# 实测：三台终端的 blitter 行为（Windows / WSL）

工具：`notcurses-demo 3.0.17` + `ncplayer -b <blitter>`
样本：`rose.png`（ImageMagick 内置图，900×591）
终端：Windows Terminal 1.2x、WezTerm、Alacritty（均为 Windows 侧 + WSL Ubuntu 26.04）

## 1. blitter 实际生效表

`ncplayer` 头部会标出**真正用上的 blitter**（`frame 000001 (half)`），
所以能区分「请求的」和「实际生效的」：

| 请求 `-b` | **WT** | **WezTerm** | **Alacritty** |
|---|---|---|---|
| `ascii` | ascii ✓ | ascii ✓ | ascii ✓ |
| `half` | half ✓ | half ✓ | half ✓ |
| `quad` | half（**回退**） | half（**回退**） | half（回退） |
| `sex` | half（**回退**） | half（**回退**） | half（回退） |
| `oct` | half（**回退**） | half（**回退**） | half（回退） |
| `braille` | braille ✓ | braille ✓ | braille ✓ |
| `pixel` | **pixel ✓（sixel）** | half（回退） | half（回退） |

**结论：在这三台机器的默认字体下，象限/六分块/八分块全部不可用，都静默降级到 half。**
原因是字体缺 Unicode 13/16 的 Legacy Computing 区块，notcurses 在
`notcurses-info` 里已经把它们标成 `2x2- 3x2- 4x2-`，`-b` 是「请求」，不是「强制」。

**这直接推翻了之前「六分块是安全上限」的判断：**
真正安全的高密度选择是 **braille（2×4 点）**——它是 Unicode 1.0 时代的区块，
所有等宽字体都有；sextant/octant 才是那个不能指望的。

## 2. 位图路径（只有 WT）

| | WT |
|---|---|
| `sixel colorregs` | 256 |
| Bmap 占输出字节 | **127.64 MiB / 149.28 MiB = 85.5%** |
| xray FPS | **24.8**（字符路径时 152.2）|
| 画面观感 | 空间平滑、**颜色有可见色带**（256 色寄存器）|

## 3. Alacritty 的撕裂：一次现场教学

用户观察：跑 `ncplayer` 时**上半屏先出现 → 停顿 → 下半屏出现**，
且密度越高，停顿前画出的行数越少。

对应的 `notcurses-demo` 数据：

| | WezTerm | **Alacritty** | WT |
|---|---|---|---|
| 总字节 | 45.59 MiB | 49.77 MiB | 149.28 MiB |
| 写入耗时 | 1.61 s | **17.01 s** | 4.23 s |
| 平均 write | 145 µs | **1.40 ms** | — |
| normal `%w` | 5% | **58%** | 5% |
| normal 实际 FPS | 106.1 | **48.2** | 94.0 |

**两个原因叠加：**

1. **Alacritty 不支持同步输出（DECSET 2026）。** notcurses 在有该能力时会把整帧
   包在 `?2026h … ?2026l` 里原子提交；没有就裸写，于是字节流到哪就画到哪 → 撕裂。
2. **WSL→ConPTY 的通道只有 ~1 MB/s**（49.77 MiB / 46.87 s，且 58% 时间在等写）。
   密度越高，一帧字节越多，撕裂的窗口越长。

这正好是我在调研里列的第 ② 条「同步输出必须作为能力位」、
第 ③ 条「带宽预算」的实测证据——而且证明了**预算模型还缺一个维度：撕裂**。
不是「能不能 30fps」，而是「这一帧会不会被看到画到一半」。

## 4. 对 mosaic 的直接改动

1. **caps 必须区分「终端支持」和「字体支持」**，且默认值取保守：
   `braille = true`（字体几乎都有）、`sextant/octant = false`（要用户显式开）。
2. **静默回退要可观测**：notcurses 的做法是对的（回退但不报错），
   但我们要额外暴露 `actual_blitter`，否则用户永远不知道自己看到的是 half。
3. **pacer 的判据从 fps 改成「帧字节数 / 通道速率」**：
   `预算 = 通道实测吞吐 × 目标帧间隔`，超了就降密度（braille→half→ascii）或降帧率。
   要留 20% 余量，否则就会看到上面那种半帧。
4. **通道速率必须实测**：拿不到就按 `%w` 估算。Alacritty 的 1 MB/s 和 WT 的
   3.8 MB/s 差 3.8 倍——这就是为什么不能写死一个「36 字节/格」的常数就完事。
