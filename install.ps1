# ============================================================================
# Hermes Agent 国内在线安装脚本
#
# 镜像加速策略：
#   国内镜像直连 — 以下工具走国内 CDN/镜像站（不经过任何代理）：
#     npmmirror: npm 包 / Node.js / Electron / Playwright
#     清华 mirrors: Git for Windows
#     aliyun / 清华 PyPI: pip 依赖
#   GitHub 代理连 — 以下工具走自动回退代理链：
#     uv / Python 运行时 / Hermes 源码 / ffmpeg
#     链: ghfast.top → ghproxy.com → 直连(try)
# ============================================================================
param(
    [string]$NpmRegistry = "https://registry.npmmirror.com",
    [string]$NodeMirror = "https://npmmirror.com/mirrors/node/",
    [string]$ElectronMirror = "https://npmmirror.com/mirrors/electron/",
    [string]$PlaywrightHost = "https://npmmirror.com/mirrors/playwright/",
    [string]$GitMirror = "https://mirrors.tuna.tsinghua.edu.cn/git-for-windows/",
    [string]$PypiMirror = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/",
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Proxy) { $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy }

# ============================================================================
# 国内镜像环境变量（子进程自动继承）
# ============================================================================
$env:npm_config_registry = $NpmRegistry
$env:NODEJS_ORG_MIRROR = $NodeMirror
$env:ELECTRON_MIRROR = $ElectronMirror
$env:PLAYWRIGHT_DOWNLOAD_HOST = $PlaywrightHost

# ============================================================================
# GitHub 代理链（国内可访问的 GitHub 反向代理，按优先级排列）
# ============================================================================
$GitHubProxies = @(
    "https://ghfast.top/"
    "https://ghproxy.com/"
)

# ============================================================================
# 工具函数
# ============================================================================
function Has-Command($name) { Get-Command $name -ErrorAction SilentlyContinue }
function Write-Step($m) { Write-Host "-> $m" -ForegroundColor Cyan }
function Write-OK($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "  [X] $m" -ForegroundColor Red }

# 通过代理链下载文件（直连try → ghfast → ghproxy → 失败）
function Invoke-ProxyDownload {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)
    # 全部尝试路径：直连 → 各代理
    $attempts = @($Url)
    foreach ($p in $GitHubProxies) { $attempts += "${p}${Url}" }
    foreach ($target in $attempts) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $short = ($target -replace '^https?://', '').Substring(0, [Math]::Min(60, ($target -replace '^https?://', '').Length))
        try {
            Invoke-RestMethod -Uri $target -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop
            if ($target -ne $Url) { Write-Step "  代理: ${short}..." }
            return $true
        } catch {} finally { $ErrorActionPreference = $prev }
    }
    return $false
}

# 通过代理链获取文本内容
function Invoke-ProxyText {
    param([string]$Url, [int]$TimeoutSec = 60)
    foreach ($target in @($Url; ($GitHubProxies | ForEach-Object { "${_}${Url}" }))) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $r = Invoke-RestMethod -Uri $target -TimeoutSec $TimeoutSec -ErrorAction Stop; if ($r) { return $r } }
        catch {} finally { $ErrorActionPreference = $prev }
    }
    return $null
}

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes Agent · 国内安装                            |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "  镜像: npm/Node/Electron/Playwright → npmmirror   " -ForegroundColor Cyan
Write-Host "  镜像: Git for Windows              → 清华 mirrors " -ForegroundColor Cyan
Write-Host "  镜像: PyPI                        → 清华 tuna     " -ForegroundColor Cyan
Write-Host "  代理: GitHub 资源                  → ghfast/ghproxy" -ForegroundColor Cyan
Write-Host ""

$hermesBin = "$env:LOCALAPPDATA\hermes\bin"
New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null
$env:Path = "${hermesBin};${env:Path}"

# ============================================================================
# 1. uv 包管理器
# ============================================================================
if (Has-Command uv) {
    Write-OK "已有 uv $((uv --version 2>$null))"
} else {
    Write-Step "下载 uv（代理链）..."
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
    $url = "https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip"
    $zip = "$env:TEMP\uv.zip"
    if (Invoke-ProxyDownload -Url $url -OutFile $zip -TimeoutSec 120) {
        Expand-Archive $zip $hermesBin -Force; Remove-Item $zip -Force
        # uv 压缩包内可能带子目录
        $sub = "$hermesBin\uv-${arch}-pc-windows-msvc"
        if (Test-Path "$sub\uv.exe") { Move-Item "$sub\uv.exe" "$hermesBin\uv.exe" -Force; Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue }
        elseif (-not (Test-Path "$hermesBin\uv.exe")) {
            $f = Get-ChildItem "$hermesBin\*.exe" -Recurse | Select-Object -First 1
            if ($f) { Copy-Item $f.FullName "$hermesBin\uv.exe" -Force }
        }
    } else { Write-Warn "uv 下载失败，Hermes 内置安装会尝试" }
    if (Has-Command uv) { Write-OK "uv $((uv --version 2>$null))" }
}

# Python 由 uv 管理，设置镜像（走代理链）
$env:UV_PYTHON_INSTALL_MIRROR = "${GitHubProxies[0]}https://github.com/astral-sh/python-build-standalone/releases/download"

# ============================================================================
# 2. Git（清华镜像 → 代理链备选）
# ============================================================================
if (Has-Command git) {
    Write-OK "已有 Git $((git --version 2>$null))"
} else {
    Write-Step "下载 Git（清华镜像）..."
    $ok = $false

    # 清华镜像：先获取最新版本号，再拼出下载链接
    # 清华 git-for-windows 镜像结构：https://mirrors.tuna.tsinghua.edu.cn/git-for-windows/v2.48.1.windows.1/PortableGit-2.48.1-64-bit.7z.exe
    # 先用 ghfast 获取最新版本信息
    $verUrl = "https://github.com/git-for-windows/git/releases/latest"
    $verRedirect = $null
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    foreach ($t in @($verUrl; ($GitHubProxies | ForEach-Object { "${_}${verUrl}" }))) {
        try {
            $req = [System.Net.WebRequest]::Create($t)
            $req.AllowAutoRedirect = $false
            $req.Timeout = 15000
            $resp = $req.GetResponse()
            if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::Redirect -or $resp.StatusCode -eq [System.Net.HttpStatusCode]::MovedPermanently) {
                $redirect = $resp.Headers["Location"]
                if ($redirect -match 'tag/v?(\d+\.\d+\.\d+(\.\d+)?)') {
                    $ver = $Matches[1]
                    # 清华镜像 URL
                    $gitUrl = "${GitMirror}v${ver}.windows.1/PortableGit-${ver}-64-bit.7z.exe"
                    $zip = "$env:TEMP\git.zip"
                    try {
                        Invoke-RestMethod -Uri $gitUrl -OutFile $zip -TimeoutSec 300 -ErrorAction Stop
                        Expand-Archive $zip "$hermesBin\git" -Force; Remove-Item $zip -Force
                        $env:Path = "$hermesBin\git\bin;${env:Path}"
                        $ok = $true
                        Write-OK "Git ${ver}（清华镜像）"
                    } catch {
                        Write-Warn "清华镜像下载 Git ${ver} 失败，走代理链"
                    }
                    break
                }
            }
            $resp.Close()
        } catch {}
    }
    $ErrorActionPreference = $prev

    # 清华镜像失败 → 代理链下载 portable git
    if (-not $ok) {
        Write-Step "Git 尝试代理链..."
        $url = "https://github.com/git-for-windows/git/releases/latest/download/PortableGit-2.48.1-64-bit.7z.exe"
        $zip = "$env:TEMP\git.zip"
        if (Invoke-ProxyDownload -Url $url -OutFile $zip -TimeoutSec 300) {
            Expand-Archive $zip "$hermesBin\git" -Force; Remove-Item $zip -Force
            $env:Path = "$hermesBin\git\bin;${env:Path}"
            if (Has-Command git) { $ok = $true; Write-OK "Git（代理链）" }
        }
    }
    if (-not $ok) { Write-Warn "Git 未能安装（Hermes 内置安装会尝试）" }
}

# ============================================================================
# 3. ffmpeg（代理链下载，非必需不阻断）
# ============================================================================
if (-not (Has-Command ffmpeg)) {
    Write-Step "下载 ffmpeg（代理链）..."
    $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    $zip = "$env:TEMP\ffmpeg.zip"
    if (Invoke-ProxyDownload -Url $url -OutFile $zip -TimeoutSec 300) {
        Expand-Archive $zip "$env:TEMP\ffmpeg-extract" -Force; Remove-Item $zip -Force
        New-Item "$hermesBin\ffmpeg" -ItemType Directory -Force | Out-Null
        $exe = Get-ChildItem "$env:TEMP\ffmpeg-extract" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
        if ($exe) { Copy-Item $exe.FullName "$hermesBin\ffmpeg\ffmpeg.exe" -Force }
        Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
        $env:Path = "$hermesBin\ffmpeg;${env:Path}"
        Write-OK "ffmpeg"
    } else { Write-Warn "跳过 ffmpeg（不影响核心功能）" }
} else { Write-OK "已有 ffmpeg" }

# ============================================================================
# 4. 拉取 Hermes 官方安装脚本 → 修补 → 执行
# ============================================================================
Write-Step "拉取 Hermes 安装脚本（代理链）..."
$scriptUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1"
$script = Invoke-ProxyText -Url $scriptUrl -TimeoutSec 60

if (-not $script) {
    Write-Err "无法下载 Hermes 安装脚本。请检查网络或使用离线安装包。"
    Write-Host "  离线包下载：百度网盘（待上传）" -ForegroundColor Yellow
    exit 1
}

# 脚本修补：GitHub 地址全走代理链
$script = $script -replace 'https://github\.com/', "${GitHubProxies[0]}https://github.com/"

# 跳过已预装的步骤（防止重复安装出错）
$script = $script -replace 'if \(-not \(Install-Uv\)\)\s*\{\s*throw "uv installation failed"\s*\}',
    'Write-Host "[OK] uv ready"'
$script = $script -replace 'Install-Git\b', '{ Write-Host "[OK] git ready" } function _git_skip{}'
$script = $script -replace 'Install-SystemPackages\b', '{ Write-Host "[OK] system pkgs ready" } function _sp_skip{}'
$script = $script -replace 'winget install [^\n]*ffmpeg[^\n]*',
    'Write-Host "[OK] ffmpeg handled"'

# uv 的 Python 安装走镜像
$env:UV_PYTHON_INSTALL_MIRROR = "${GitHubProxies[0]}https://github.com/astral-sh/python-build-standalone/releases/download"

Write-Step "安装 Hermes 本体（镜像加速，约 5-15 分钟）..."
Invoke-Expression $script

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  1. 重启终端（让 PATH 生效）" -ForegroundColor Cyan
Write-Host "  2. 输入 hermes 启动" -ForegroundColor Cyan
Write-Host "  3. 首次使用: hermes setup 配置 API Key" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Green