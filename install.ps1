# ============================================================================
# Hermes Agent 国内在线安装脚本
# 用法: irm https://gitee.com/xxx/hermes-install-cn/raw/main/install.ps1 | iex
# 或:  .\install.ps1
# ============================================================================
param(
    [string]$Mirror = "https://ghfast.top/",
    [string]$NpmRegistry = "https://registry.npmmirror.com",
    [string]$NodeMirror = "https://npmmirror.com/mirrors/node/",
    [string]$ElectronMirror = "https://npmmirror.com/mirrors/electron/",
    [string]$PlaywrightHost = "https://npmmirror.com/mirrors/playwright/",
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"
if ($Proxy) { $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy }

$env:npm_config_registry = $NpmRegistry
$env:NODEJS_ORG_MIRROR = $NodeMirror
$env:ELECTRON_MIRROR = $ElectronMirror
$env:PLAYWRIGHT_DOWNLOAD_HOST = $PlaywrightHost
$env:UV_PYTHON_INSTALL_MIRROR = "${Mirror}https://github.com/astral-sh/python-build-standalone/releases/download"

$hermesBin = "$env:LOCALAPPDATA\hermes\bin"
New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null
$env:Path = "${hermesBin};${env:Path}"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes Agent 国内安装 (镜像加速)                    |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta

function Has-Command($name) { Get-Command $name -ErrorAction SilentlyContinue }

# ============================================================================
# 1. uv
# ============================================================================
if (Has-Command uv) {
    Write-Host "-> [已有] uv $((uv --version 2>$null))" -ForegroundColor Green
} else {
    Write-Host "-> 正在安装 uv..." -ForegroundColor Cyan
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
    $zip = "$env:TEMP\uv.zip"
    Invoke-RestMethod -Uri "${Mirror}https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip" -OutFile $zip -TimeoutSec 120
    Expand-Archive $zip $hermesBin -Force; Remove-Item $zip -Force
    if (Test-Path "$hermesBin\uv-${arch}-pc-windows-msvc\uv.exe") {
        Move-Item "$hermesBin\uv-${arch}-pc-windows-msvc\uv.exe" "$hermesBin\uv.exe" -Force
        Remove-Item "$hermesBin\uv-${arch}-pc-windows-msvc" -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path "$hermesBin\uv.exe")) {
        $f = Get-ChildItem "$hermesBin\*.exe" -Recurse | Select-Object -First 1
        if ($f) { Copy-Item $f.FullName "$hermesBin\uv.exe" -Force }
    }
    Write-Host "  [OK] uv $((uv --version 2>$null))" -ForegroundColor Green
}

# ============================================================================
# 2. Git
# ============================================================================
if (Has-Command git) {
    Write-Host "-> [已有] Git $((git --version 2>$null))" -ForegroundColor Green
} else {
    Write-Host "-> 正在安装 Git（镜像加速）..." -ForegroundColor Cyan
    try {
        $zip = "$env:TEMP\git.zip"
        Invoke-RestMethod -Uri "${Mirror}https://github.com/git-for-windows/git/releases/latest/download/PortableGit-2.48.1-64-bit.7z.exe" -OutFile $zip -TimeoutSec 300
        Expand-Archive $zip "$hermesBin\git" -Force; Remove-Item $zip -Force
        $env:Path = "$hermesBin\git\bin;${env:Path}"
        Write-Host "  [OK] Git $((git --version 2>$null))" -ForegroundColor Green
    } catch {
        Write-Host "[!] Git 镜像下载失败，尝试 winget..." -ForegroundColor Yellow
        winget install Git.Git 2>$null
    }
}

# ============================================================================
# 3. ffmpeg
# ============================================================================
if (Has-Command ffmpeg) {
    Write-Host "-> [已有] ffmpeg" -ForegroundColor Green
} else {
    Write-Host "-> 正在安装 ffmpeg（镜像加速）..." -ForegroundColor Cyan
    try {
        $zip = "$env:TEMP\ffmpeg.zip"
        Invoke-RestMethod -Uri "${Mirror}https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $zip -TimeoutSec 300
        Expand-Archive $zip "$env:TEMP\ffmpeg-extract" -Force; Remove-Item $zip -Force
        New-Item "$hermesBin\ffmpeg" -ItemType Directory -Force | Out-Null
        $exe = Get-ChildItem "$env:TEMP\ffmpeg-extract" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
        if ($exe) { Copy-Item $exe.FullName "$hermesBin\ffmpeg\ffmpeg.exe" -Force }
        Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
        $env:Path = "$hermesBin\ffmpeg;${env:Path}"
        Write-Host "  [OK] ffmpeg" -ForegroundColor Green
    } catch { Write-Host "[!] ffmpeg 跳过（不影响核心功能）" -ForegroundColor Yellow }
}

# ============================================================================
# 4. 拉取原始 install.ps1 并修补执行
# ============================================================================
Write-Host "-> 正在拉取 Hermes 安装脚本..." -ForegroundColor Cyan
$script = Invoke-RestMethod -Uri "${Mirror}https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1" -TimeoutSec 60
$script = $script -replace 'https://github\.com/', "${Mirror}https://github.com/"
$script = $script -replace 'if \(-not \(Install-Uv\)\)\s*\{ throw "uv installation failed" \}',
    'Write-Host "[OK] uv ready" -ForegroundColor Green'
$script = $script -replace 'Install-Git|Install-SystemPackages',
    '{ Write-Host "[OK] pre-installed by china installer" } function _noop{}'
$script = $script -replace 'winget install [^\n]*ffmpeg[^\n]*',
    'Write-Host "[OK] ffmpeg pre-installed"'

Write-Host "-> 正在安装 Hermes 本体（镜像加速，5-15 分钟）..." -ForegroundColor Cyan
Invoke-Expression $script

Write-Host "`n[OK] 安装完成！重启终端后输入 hermes 即可使用。" -ForegroundColor Green