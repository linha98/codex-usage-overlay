# Codex 用量悬浮窗

一个仅面向 Windows 的轻量悬浮窗，显示：

- Codex 当前是否正在执行本地任务；
- 当前周用量百分比；
- 剩余重置机会和最近一张的东八区到期时间。

窗口固定为约 `168 × 92` 像素，无系统标题栏并始终置顶。

## 直接使用

从 GitHub Releases 下载 `Codex悬浮窗.exe`，双击运行。源码仓库不跟踪 `dist` 中的构建产物。

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
