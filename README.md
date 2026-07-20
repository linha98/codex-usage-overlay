# Codex 用量悬浮窗

一个轻量 Codex 用量悬浮窗，提供 Windows 源码版与 macOS 原生版，显示：

- Codex 当前是否正在执行本地任务；
- 当前周用量百分比；
- 剩余重置机会和最近一张的东八区到期时间。

窗口无系统标题栏并始终置顶。

## macOS：点击即用

适用于 Apple Silicon（M 系列）且系统版本为 macOS 13 或更高。无需安装 Python。

1. 直接双击 [`dist/Codex悬浮窗.app`](dist/Codex悬浮窗.app)；若未构建，运行 `zsh ./build-mac.sh`。
2. 首次被 macOS 拦截时，在 Finder 中按住 Control 点按应用，选择“打开”。
3. 应用会在 Dock 和菜单栏显示图标，并在右上角显示悬浮窗。拖动窗口可调整位置，拖动右下角可调整大小；右键窗口可刷新、隐藏或退出。

菜单栏菜单还提供刷新、鼠标穿透、登录时打开和退出。应用会自动寻找 ChatGPT/Codex 安装的本机 `codex` 命令；也可以用 `CODEX_EXE` 指向它。

Codex 用量每分钟自动刷新，重置次数每小时自动刷新；“立即刷新”会同时刷新两项。

## 直接使用

从 GitHub Releases 下载 `Codex悬浮窗.exe`，双击运行。源码仓库不跟踪 Windows `dist` 中的构建产物。

- 拖动窗口任意区域可以移动窗口。
- 右键窗口可刷新、隐藏、切换鼠标穿透或开机启动。
- 双击系统托盘图标可重新显示窗口。
- 开机启动、鼠标穿透等功能可从托盘右键菜单切换。

## 数据与隐私

- 用量通过本机 `codex app-server` 的 stdio 接口读取。
- 重置机会在启动时立即读取，之后每小时静默刷新一次；手动刷新会同时更新用量和重置机会。
- 重置机会只通过 HTTPS 请求 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`。
- 程序从 `CODEX_HOME\auth.json` 或 `%USERPROFILE%\.codex\auth.json` 读取登录令牌，令牌只在请求期间保存在内存，不打印、不记录、不另行保存。
- 任务状态只识别 `%USERPROFILE%\.codex\sessions` 中的 `task_started`、`task_complete`、`turn_aborted` 类型标记。
- 程序不解析、保存或上传提示词、回复和文件内容。

## 源码运行

在 PowerShell 中执行：

```powershell
.\run.ps1
```

验证 Codex 用量接口：

```powershell
$env:PYTHONPATH = '.\src'
python -m codex_overlay --probe
```

## 重新构建

```powershell
.\build.ps1
```

构建脚本会在项目目录的 `.build-tools` 中安装构建依赖，并输出单文件程序到 `dist`。

## 开源许可

本项目使用 [MIT License](LICENSE)。

## 故障排查

- 显示“未找到 codex.exe”：确认 Codex 已安装，或设置 `CODEX_EXE` 环境变量指向 `codex.exe`。
- 显示连接失败：先在 Codex 中确认已经登录，然后点击刷新。
- 重置次数显示 `--`：确认本机 Codex 已使用 ChatGPT 账号登录，且认证文件中包含可用登录凭据。
- 显示状态未知：通常是上次任务异常退出留下了未闭合记录；新任务开始或完成后会自动校正。
