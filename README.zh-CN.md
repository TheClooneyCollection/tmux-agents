# tmux-agents

[English](README.md) | 简体中文

**子 agent 不该在任务结束后就消失。** 内置的子 agent 都在你看不见的地方跑，最后只给你一段总结，背后的过程全没了。

tmux-agents 让每个 Claude 或 Codex 子 agent 都在自己的 tmux 窗口里运行。你可以在实时预览里看它干活，也可以随时切进去给它指示。

agent 之间可以互相派任务、同步进度。它们的 pane 会一直保留到你关闭为止，对话之后也还在：Codex 用 `codex resume`，Claude 用 `claude --resume` 就能找回来。

看得见过程，留得住历史，随时接着做。

- **真实的会话，不是黑盒。** 每个子 agent 都是完整的 Claude 或 Codex 会话，所有历史都在屏幕上。你可以批准提示、追问，或者中途纠正它。
- **一眼看出谁在等你。** 状态栏上方有一行，显示每个子 agent 是在工作、已完成、在等权限，还是在等你。
- **agent 之间能对话。** 对 Claude 说"连接 codex，让它 review 这个 diff"，Codex 的回复会作为一条新消息回到 Claude。
- **不打扰你。** 子 agent 放在每个项目各自的隐藏 session 里，不会改动你的布局；你在某个 pane 里打字时，消息也不会插进来。
- **只需要 tmux 和 bash。** 不用跑任何服务，状态都存在 tmux pane 上。

## 截图

<p align="center">
  <img src="docs/message-request.png" width="49%" alt="Claude 发出的请求出现在 Codex 的 pane 里">
  <img src="docs/message-reply.png" width="49%" alt="Codex 的回复回到 Claude 的 pane">
</p>

<p align="center">Claude 请 Codex 做 review，回复作为一条新消息回来。</p>

<p align="center">
  <img src="docs/agent-list.png" width="49%" alt="agent 列表：子 agent 的状态、父 agent，以及选中项的实时预览">
  <img src="docs/popup.png" width="49%" alt="从列表里用 popup 打开一个隐藏的 Codex 子 agent">
</p>

<p align="center"><code>prefix + a</code> 列出你的子 agent，带实时预览。用 popup 打开一个，就能回答它或者给它指示。</p>

状态栏：状态栏上方的一行会统计子 agent，有 agent 需要你时变成红色或黄色：

```
      ⠹ auth-review: reading src/auth.ts  │  api ⠹ 2 ✓ 1 · blog ⠹ 1
```

设计说明、协议细节和已知的坑：[DESIGN.md](DESIGN.md)（英文）。

## 安装

最简单的方式：让 Claude Code 或 Codex 帮你装。

> 按照 https://github.com/TheClooneyCollection/tmux-agents/blob/main/skills/tmux-agents-setup/SKILL.md 帮我安装 tmux-agents

它会检查你的环境、运行安装脚本，每处配置改动都先给你看，然后带你走一遍 quick start。之后对任何 agent 说 "tmux-agents quick start"，就能再走一遍。

用户级 skill 安装可以使用下面的 [skills CLI](https://skills.sh)，也可以运行手动安装步骤中的 `./install.sh`。使用 CLI 后，对你的 agent 说 "set up tmux-agents"，继续安装命令并配置 tmux：

```sh
npx skills add TheClooneyCollection/tmux-agents -g
```

### 手动安装

需要 tmux 3.2+ 和 bash。`fzf` 可选（选择器和实时 agent 列表会更好用）。

```sh
git clone https://github.com/TheClooneyCollection/tmux-agents.git
cd tmux-agents
./install.sh            # 先加 --dry-run 看看它会做什么
```

`install.sh` 会：

- 把 `tmux-*` 命令链接到 `~/.local/bin`（用 `BIN_DIR` 修改）
- 把 `tmux-agents`、`tmux-agents-setup`、`tmux-agents-perf` 和 `agent-chain` 四个 skill 链接到 `~/.claude/skills/` 和你的 Codex home
- 复制 Codex rules（Codex 会忽略符号链接的 `.rules` 文件）
- 保留链接目标处的真实文件和目录；加 `--force` 时，先备份为 `DEST.bak.YYYYmmddHHMMSS`，再建立链接

然后把这些加到你自己的配置里（`install.sh` 会用你的实际路径打印出来）：

| | |
| --- | --- |
| **tmux** | 在 `~/.tmux.conf` 里加 `source-file ~/path/to/tmux-agents/tmux/tmux-agents.conf`，然后重新加载 |
| **PATH** | `~/.local/bin` |
| **Claude** | 把 [`integrations/claude/settings.json`](integrations/claude/settings.json) 里的 `allow` 规则合并进 `~/.claude/settings.json` |
| **Codex** | wrapper：[`integrations/fish/functions/`](integrations/fish/functions) 或 [`integrations/sh/codex.sh`](integrations/sh/codex.sh) |

<details>
<summary>每一项是做什么的</summary>

- **tmux：** `prefix + a`（agent 列表）、`prefix + A`（连接）、子 agent 状态行，以及刷新边框、响铃提醒和发送排队消息的 hooks。如果命令没有链接到 `~/.local/bin`，在 `source-file` 那行之前加上 `%hidden TMUX_AGENTS_BIN="/那个/目录"`。
- **Claude：** agent 发消息、查看、spawn、报告进度、给自己或后代改名、关闭自己的子 agent 时都不用再弹确认。`tmux-connect`（不带 `--from`）、`tmux-disconnect`、不带参数的 `tmux-dismiss` 和不带 `--from` 的 `tmux-rename` 仍然由你来操作，照样会询问。
- **Codex：** Codex 在一个共享的后台进程里执行命令，里面的 `$TMUX_PANE` 可能属于别的 pane，所以要靠 wrapper 把每个 Codex 固定到它自己的 pane（见 DESIGN.md）。fish 用户把函数复制到 `~/.config/fish/functions/`；bash/zsh 用户在 `~/.bashrc` 或 `~/.zshrc` 里 `source` 那个 sh 文件。
- **可选：** 在 `CLAUDE.md` / `AGENTS.md` 里告诉 agent 所有子 agent 都用 `tmux-spawn` 开。skill 里有具体说明。

</details>

在实际安装的 checkout 中更新：分支安装使用 `git pull --ff-only`；detached/tag 安装使用 `git fetch --tags`，再用 `git checkout <new-tag>` 切换到你选择的 tag。然后在该目录重新运行 `./install.sh`，更新 rules 并重建 skill 链接，包括指向旧 skill 目录的链接。

有多个 Codex 账号？见[使用指南](docs/guide.md#more-than-one-codex-account)（英文）。

### 如果 popup 打开很慢

tmux-agents 本身很快（构建一次列表约 0.1 秒），但 tmux 会通过你的 `default-shell` 来运行每个 popup 和每个新 agent 的窗口，而这个 shell 会先读取它的配置。检查一下：

```sh
tmux show -gv default-shell
time fish -c true        # 换成你的 shell；和 --no-config / --norc / -f 的结果对比
```

如果这里要几百毫秒，每次按 `prefix + a` 都要多等这么久（列表本身会先画出提示符，紧接着加载条目）。解决方法见 [docs/performance.md](docs/performance.md)，或者让你的 agent "查一下 tmux-agents 为什么慢"（`tmux-agents-perf` skill）。

## 配置

在 `tmux.conf` 中设置偏好，也可以用 `tmux set -g` 实时修改。环境变量优先于 option，再使用下表的默认值。给定名字的 `--exact` 优先级最高。后续使用 `tmux-spawn` 或 `tmux-rename` 输出的完整名字。

```tmux
set -g @tmux_agents_name_format exact
```

| Option | 环境变量覆盖 | 默认值 | 用途 |
| --- | --- | --- | --- |
| `@tmux_agents_name_format` | `TMUX_AGENTS_NAME_FORMAT` | `prefixed` | 给定名字格式：`exact` 或 `prefixed` |
| `@tmux_agents_max_depth` | `TMUX_AGENTS_MAX_DEPTH` | `2` | 子 agent 最大层数 |
| `@tmux_agents_codex_homes` | `TMUX_AGENTS_CODEX_HOMES` | `none` | 额外账户，格式为 `PROFILE=CODEX_HOME` |
| `@tmux_agents_session_prefix` | `TMUX_AGENTS_PREFIX` | `agents` | 隐藏 session 名称前缀 |
| `@tmux_agents_resume_days` | `TMUX_AGENTS_RESUME_DAYS` | `7` | 列表保留已关闭 agent 的天数 |
| `@tmux_agents_preview_secs` | `TMUX_AGENTS_PREVIEW_SECS` | `0.5` | 预览刷新间隔，单位秒 |
| `@tmux_agents_blink_secs` | `TMUX_AGENTS_BLINK_SECS` | `60` | 需要关注多久后开始闪烁，单位秒 |
| `@tmux_agents_chip_fps` | 无 | `10` | chip 动画帧率 |
| `@tmux_agents_ask_idle_secs` | `TMUX_ASK_IDLE_SECS` | `8` | 无按键多久后可投递，单位秒 |
| `@tmux_agents_ask_copy_idle_secs` | `TMUX_ASK_COPY_IDLE_SECS` | `300` | 复制模式空闲多久后自动退出，单位秒；`0` 禁用 |
| `@tmux_agents_ask_queue_secs` | `TMUX_ASK_QUEUE_SECS` | `1800` | 排队多久后显示消息等待，单位秒；消息继续保留 |
| `@tmux_agents_ask_max_lines` | `TMUX_ASK_MAX_LINES` | `60` | 超过此行数的长消息保存为文件 |
| `@tmux_agents_ask_enter_delay` | `TMUX_ASK_ENTER_DELAY` | `0.5` | 粘贴到按 Enter 的间隔，单位秒 |
| `@tmux_agents_connect_highlight` | `TMUX_CONNECT_HIGHLIGHT` | `bg=colour24` | 连接选择器中目标 pane 的高亮样式 |

`TMUX_AGENTS_CODEX_HOMES` 仍在本地覆盖和 option 均未设置时回退到 tmux 全局环境。每次命令调用读取一次设置；已有选择器或 chip daemon 的缓存设置需重启相应进程后更新。将覆盖值放在 `source-file tmux-agents.conf` 之后，因为该文件会设置默认 chip 帧率。内部 pane 状态和测试 hook 不是用户设置。

## 快速上手

1. 把一个 tmux 窗口分成两半，一边启动 `claude`，另一边启动 `codex`。
2. 对 Claude 说："用 tmux-agents 连接 codex 那个 pane，让它 review 这个 diff"。请求会出现在 Codex 的 pane 里，回复会回到 Claude。
3. 对 Claude 说："开一个子 agent 给 parser 加测试"。它在隐藏窗口里运行，状态栏上方那一行会显示它的进度。
4. 按 `prefix + a` 查看它。按 Enter 用 popup 打开，按 `prefix + d` 返回。
5. 对 Claude 说："start the chain"。它会成为和你对话的 main agent，再开一个负责协调的 secondary 和一个负责实现的 Codex worker，三个并排在你的窗口里（`agent-chain` skill）。

也可以让 agent 带你走一遍：对它说 "tmux-agents quick start"。

## 快捷键

| 按键 | |
| --- | --- |
| `prefix + a` | agent 列表，带实时预览 |
| `prefix + A` | 把当前 pane 连接到另一个 pane（`ctrl-a`：任意窗口） |
| `prefix + d` | 在 popup 里：返回列表。在列表里：关闭列表 |

列表默认显示当前窗口及其下属 agent，所有窗口中需要你处理的子 agent 都置顶。

列表里：`enter` 打开 · `ctrl-o` 跳过去 · `ctrl-x` 关闭 agent · `ctrl-d` 关闭所有已完成的 · `ctrl-a` 切换所有 pane / 子 agent · `ctrl-t` 当前窗口 / 所有窗口

关掉的子 agent 会在列表底部的 `closed` 区保留 7 天：按 `enter` 就能带着完整对话重新打开。也可以让它的父 agent 帮你重开。

状态：`⠹` 工作中 · `○` 空闲（还没有任务）· `✓` 已完成 · `⚠` 等待权限（红）· `◆` 需要你（黄）· `✉` 有消息在等你停止打字或滚动 · `✗` 已退出

## 命令

这些命令由 agent 替你运行，每个都支持 `--help`。

| 命令 | |
| --- | --- |
| `tmux-connect` | 给当前 pane 命名并连接到另一个 pane |
| `tmux-rename` | 修改 agent 标签，保留身份、历史和连接 |
| `tmux-ask` | 给已连接的 agent 发消息 |
| `tmux-spawn` | 在隐藏窗口或 `--split` 指定的可见分屏中启动子 agent |
| `tmux-agents` | agent 列表（`prefix + a`） |
| `tmux-peers`、`tmux-peek` | 查看连接关系；读取另一个 pane 的内容 |
| `tmux-dismiss`、`tmux-disconnect` | 关闭子 agent；断开 pane 之间的连接 |
| `tmux-agent-report` | 报告进度，显示在状态行上 |

操作存活 agent 的命令仍然使用名字；只有选择同名历史对话时才需要 ID。名字只是标签：复用已关闭 agent 的名字不会覆盖任何一方的历史。列表用关闭时间、父 agent 和项目区分同名记录；行内不显示 ID，已关闭记录的预览可以显示。脚本和 agent 可用 `tmux-peers --ids`、`tmux-spawn --list-closed` 查看 ID；`--resume NAME` 有歧义时，用 `--resume-id ID` 精确重开指定对话。

消息如何传递、子 agent 的细节、设置项和实现原理：见[使用指南](docs/guide.md)（英文）。

## 许可证

MIT，见 [LICENSE](LICENSE)。
