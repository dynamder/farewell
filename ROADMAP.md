# Roadmap

方向，不是承诺。状态只有三档：done / next / later。

| | 里程碑 | 状态 | 验收 |
| --- | --- | --- | --- |
| M0 | 与终端无关的核心：`types` `source` `blit` `ansi` | done | 120×36 的 raymarch 1.4 ms/帧 |
| M1 | 能力位与来源：`caps` | done | 三台终端的实测场景各有一条单测 |
| M2 | 帧装配：`present` | done | 整帧一次写出；同步标记只在终端支持时出现 |
| M3 | 宿主接线：尺寸、输入、节流 | done | demo 填满窗口，按键退出，可跑满一帧预算 |
| M4 | `sixel` 编码 | later | Windows Terminal 里显示一张照片 |
| M5 | `pacer`：按字节预算降档 | later | Alacritty 上降档后不再撕裂 |
| M6 | 可复用技法：符号墨量、抖动、时间抖动 | later | 同一张图的四档对照 |

## 待定

- **能力探测**：`caps.Probe` 目前只由宿主填，demo 用 `--caps` 顶着。自己写 DA1 /
  DECRQM（还要处理 tmux 透传、超时、部分读），还是把 vaxis 只当 Tty + 探测层拿进
  demo？两条路都不影响包本身零依赖。

## 非目标

- 不做 TUI 框架：控件、布局、事件循环交给 vaxis
- 不做终端模拟器
- 不做场景或动画库：那是使用者的工作
- 不维护终端能力数据库：探测属于宿主，这里只定义「答案的含义」

## 背景

- [终端图形栈调研](docs/architecture-survey.md)：前人做了什么，哪些该统一
- [库设计](docs/library-design.md)：边界、模块、技法来源
- [实测能力](docs/measured-caps.md)：三台终端上的 blitter 与带宽实测
