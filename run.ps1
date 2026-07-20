$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
$pythonArgs = @()

if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
    $pythonArgs = @('-3')
}
if ($null -eq $pythonCommand) {
    throw '未找到 Python。请直接运行 dist\Codex悬浮窗.exe，或安装 Python 3.10 以上版本。'
}
$python = $pythonCommand.Source

$env:PYTHONPATH = Join-Path $projectPath 'src'
& $python @pythonArgs -m codex_overlay
