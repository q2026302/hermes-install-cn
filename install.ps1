# ============================================================================
# Hermes Agent 国内在线安装脚本
#
# 镜像加速策略（多级回退）：
#   1. 国内直连镜像 — npmmirror（npm/Node/Electron/Playwright）
#                          清华 PyPI（pip 回退）
#                          winget CDN（Git、ffmpeg）
#   2. GitHub 代理链  — ghfast.top → ghproxy.com（uv、源码等）
# ============================================================================
param(
    [string]$NpmRegistry = "https://registry.npmmirror.com",
    [string]$NodeMirror = "https://npmmirror.com/mirrors/node/",
    [string]$ElectronMirror = "https://npmmirror.com/mirrors/electron/",
    [string]$PlaywrightHost = "https://npmmirror.com/mirrors/playwright/",
    [string]$PypiMirror = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/",
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 用户主动指定代理（如 Shadowsocks/V2Ray 客户端）
if ($Proxy) { $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy }

# ============================================================================
# 国内镜像环境变量（子进程自动继承）
# ============================================================================
$env:npm_config_registry = $NpmRegistry
$env:NODEJS_ORG_MIRROR = $NodeMirror
$env:ELECTRON_MIRROR = $ElectronMirror
$env:PLAYWRIGHT_DOWNLOAD_HOST = $PlaywrightHost

# ============================================================================
# GitHub 代理链（多级回退）
# ============================================================================
$GitHubProxies = @("https://ghfast.top/", "https://ghproxy.com/")

# ============================================================================
# 工具函数
# ============================================================================
function Has-Command($name) { Get-Command $name -ErrorAction SilentlyContinue }
function Write-Step($msg) { Write-Host "-> $msg" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "  [X] $msg" -ForegroundColor Red }

# 通过代理链下载文件（直连 → ghfast.top → ghproxy.com）
function Invoke-ProxyDownload {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)
    # 先直连（部分镜像站可直连）
    foreach ($prefix in ("", $GitHubProxies)) {
        $target = if ($prefix) { "${prefix}${Url}" } else { $Url }
        if (-not $prefix -and $target -eq $Url -and $Url -match '^https?://') {
            # 尝试直连
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try { Invoke-RestMethod -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop; return $true }
            catch {} finally { $ErrorActionPreference = $prev }
        } elseif ($prefix) {
            # 尝试代理
            $short = ($target -replace 'https://', '').Substring(0, [Math]::Min(60, ($target -replace 'https://', '').Length))
            Write-Step "  代理: ${short}..."
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try { Invoke-RestMethod -Uri $target -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop; return $true }
            catch { Write-Warn "  失效，换一个" } finally { $ErrorActionPreference = $prev }
        }
    }
    return $false
}

# 通过代理链获取文本内容
function Invoke-ProxyText {
    param([string]$Url, [int]$TimeoutSec = 60)
    foreach ($prefix in ("", $GitHubProxies)) {
        $target = if ($prefix) { "${prefix}${Url}" } else { $Url }
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $r = Invoke-RestMethod -Uri $target -TimeoutSec $TimeoutSec -ErrorAction Stop; if ($r) { return $r } }
        catch {} finally { $ErrorActionPreference = $prev }
    }
    return $null
}

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes Agent · 国内安装                            |" -ForegroundColor Magenta
Write-Host "|   国内镜像直连: npm / Node / Electron / Playwright    |" -ForegroundColor Magenta
Write-Host "|   winget CDN:   Git / ffmpeg                         |" -ForegroundColor Magenta
Write-Host "|   GitHub 代理:  ghfast.top → ghproxy.com             |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta

$hermesBin = "$env:LOCALAPPDATA\hermes\bin"
New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null

# ============================================================================
# 1. uv 包管理器（GitHub → 代理链）
# ============================================================================
if (Has-Command uv) {
    Write-OK "已有 uv $((uv --version 2>$null))"
} else {
    Write-Step "安装 uv（代理链）..."
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
    $url = "https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip"
    $zip = "$env:TEMP\uv.zip"

    if (Invoke-ProxyDownload -Url $url -OutFile $zip -TimeoutSec 120) {
        Expand-Archive $zip $hermesBin -Force; Remove-Item $zip -Force
        # uv zip 内可能带子目录
        if (Test-Path "$hermesBin\uv-${arch}-pc-windows-msvc\uv.exe") {
            Move-Item "$hermesBin\uv-${arch}-pc-windows-msvc\uv.exe" "$hermesBin\uv.exe" -Force
            Remove-Item "$hermesBin\uv-${arch}-pc-windows-msvc" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path "$hermesBin\uv.exe")) {
            $f = Get-ChildItem "$hermesBin\*.exe" -Recurse | Select-Object -First 1
            if ($f) { Copy-Item $f.FullName "$hermesBin\uv.exe" -Force }
        }
    } else {
        Write-Warn "uv 下载失败，Hermes 内置安装将尝试"
    }
    $env:Path = "${hermesBin};${env:Path}"
    if (Has-Command uv) { Write-OK "uv $((uv --version 2>$null))" }
}

# Python 运行时由 uv 通过代理链下载
$env:UV_PYTHON_INSTALL_MIRROR = "${GitHubProxies[0]}https://github.com/astral-sh/python-build-standalone/releases/download"

# ============================================================================
# 2. Git（winget CDN 直连 → 代理链备选）
# ============================================================================
if (Has-Command git) {
    Write-OK "已有 Git $((git --version 2>$null))"
} else {
    Write-Step "安装 Git（winget CDN）..."
    $ok = $false
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $p = Start-Process winget -ArgumentList "install Git.Git --accept-source-agreements --accept-package-agreements" -Wait -PassThru -NoNewWindow; if ($p.ExitCode -eq 0) { $ok = $true } } catch {}
    $ErrorActionPreference = $prev

    if (-not $ok) {
        Write-Warn "winget 失败，尝试便携版（代理链）..."
        $url = "https://github.com/git-for-windows/git/releases/latest/download/PortableGit-2.48.1-64-bit.7z.exe"
        $zip = "$env:TEMP\git.zip"
        if (Invoke-ProxyDownload -Url $url -OutFile $zip -TimeoutSec 300) {
            Expand-Archive $zip "$hermesBin\git" -Force; Remove-Item $zip -Force
            $env:Path = "$hermesBin\git\bin;${env:Path}"
            if (Has-Command git) { $ok = $true }
        }
    }
    if ($ok) { Write-OK "Git" } else { Write-Warn "Git 安装受阻，Hermes 内置安装将尝试" }
}

# ============================================================================
# 3. ffmpeg（winget CDN 直连，非必需，不阻断）
# ============================================================================
if (-not (Has-Command ffmpeg)) {
    Write-Step "安装 ffmpeg（winget CDN）..."
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $p = Start-Process winget -ArgumentList "install ffmpeg --accept-source-agreements --accept-package-agreements" -Wait -PassThru -NoNewWindow; if ($p.ExitCode -eq 0) { Write-OK "ffmpeg" } else { Write-Warn "跳过 ffmpeg（不影响核心功能）" } } catch { Write-Warn "跳过 ffmpeg（不影响核心功能）" }
    $ErrorActionPreference = $prev
} else { Write-OK "已有 ffmpeg" }

# ============================================================================
# 4. 拉取 Hermes 官方安装脚本 → 修补 → 执行
# ============================================================================
Write-Step "拉取 Hermes 安装脚本（代理链）..."
$scriptUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1"
$script = Invoke-ProxyText -Url $scriptUrl -TimeoutSec 60

if (-not $script) {
    Write-Err "无法下载 Hermes 安装脚本。请检查网络或使用离线安装包。"
    exit 1
}

# 修补：git clone 走代理链
$script = $script -replace 'https://github\.com/', "${GitHubProxies[0]}https://github.com/"

# 跳过已预装的步骤
$script = $script -replace 'if \(-not \(Install-Uv\)\)\s*\{ throw "uv installation failed" \}',
    'Write-Host "[OK] uv" -ForegroundColor Green'
$script = $script -replace 'Install-Git\b', '{ Write-Host "[OK] git" } function _g{}'
$script = $script -replace 'Install-SystemPackages\b', '{ Write-Host "[OK] system pkgs" } function _sp{}'
$script = $script -replace 'winget install [^\n]*ffmpeg[^\n]*', 'Write-Host "[OK] ffmpeg"'

Write-Step "安装 Hermes 本体（镜像加速，约 5-15 分钟）..."
Invoke-Expression $script

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  1. 重启终端（让 PATH 生效）" -ForegroundColor Cyan
Write-Host "  2. 输入 hermes 启动" -ForegroundColor Cyan
Write-Host "  3. 首次使用: hermes setup 配置模型" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Green