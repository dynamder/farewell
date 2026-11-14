# AGENTS.md

## 代码风格

几乎不写注释。用代码本身表达意图和约束：清晰的命名、精确的类型、`comptime` 约束。

只允许两种注释，且都面向使用者：

- `//!` 模块的简要说明，通常应该一句话。
- `///` 公共 API 的契约：用途，参数含义、返回什么、前置条件、以及特别要注意的事项。

不允许：解释实现动机、复述代码、记录历史、那些属于 commit message
和 `docs/`。

## 沙箱

`zig build` 需要写全局缓存。本机沙箱拒绝写全局缓存。
报 `manifest_create AccessDenied`，所以每次构建前显式指定：

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig/global"
export ZIG_LOCAL_CACHE_DIR="$PWD/.cache/zig/local"
```

这只是沙箱限制。正常机器不需要设置，用默认位置即可。

不要跑 `zig fmt .`：它会递归进 `research/`（里面是第三方源码，含一些编译不过的
Zig 文件，`zig fmt` 会直接报错退出）。用 `zig build fmt`，范围固定在
`build.zig` / `src` / `demo`。

## 目录

| 路径 | 归属 |
| --- | --- |
| `src/` `demo/` `build.zig` `build.zig.zon` | 包内容，`.paths` 列出 |
| `docs/` `tools/` | 入库，但不属于包 |
| `research/` | 不入库：前人快照、抓帧原料、成品图 |
| `.cache/` | 不入库：zig 缓存、WSL 二进制 |

新增运行时资源（字体、shader、数据文件）必须写进 `build.zig.zon` 的 `.paths`。
漏了就会出现「本地能跑、`zig fetch` 下来缺文件」。

## 提交

小步提交，每一步都能通过 `zig build test`。消息格式遵循conventional commit `type(scope): summary`，
正文写清动机而不是细节。
