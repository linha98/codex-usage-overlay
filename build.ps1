$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
$pythonArgs = @()

if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
    $pythonArgs = @('-3')
}
if ($null -eq $pythonCommand) {
    throw '构建需要 Python 3.10 以上版本。'
}
$python = $pythonCommand.Source

$buildTools = Join-Path $projectPath '.build-tools'
New-Item -ItemType Directory -Path $buildTools -Force | Out-Null
& $python @pythonArgs -m pip install --disable-pip-version-check --target $buildTools -r (Join-Path $projectPath 'requirements.txt') -r (Join-Path $projectPath 'requirements-build.txt')
if ($LASTEXITCODE -ne 0) { throw '安装构建依赖失败。' }

$sourcePath = Join-Path $projectPath 'src'
$entryPoint = Join-Path $projectPath 'launcher.py'
$env:PYTHONPATH = "$buildTools;$sourcePath"
& $python @pythonArgs -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --windowed `
    --name 'Codex悬浮窗' `
    --distpath (Join-Path $projectPath 'dist') `
    --workpath (Join-Path $projectPath 'build') `
    --specpath $projectPath `
    --paths $buildTools `
    --paths $sourcePath `
    --hidden-import win32timezone `
    $entryPoint
if ($LASTEXITCODE -ne 0) { throw '生成 exe 失败。' }

Copy-Item -LiteralPath (Join-Path $projectPath 'README.md') -Destination (Join-Path $projectPath 'dist\使用说明.md') -Force
Write-Host "构建完成：$(Join-Path $projectPath 'dist\Codex悬浮窗.exe')"
