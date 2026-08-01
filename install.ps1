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
#     链: 直连 → gh-proxy.com → ghfast.top
# ============================================================================
param(
    [string]$NpmRegistry = "https://registry.npmmirror.com",
    [string]$NodeMirror = "https://npmmirror.com/mirrors/node/",
    [string]$ElectronMirror = "https://npmmirror.com/mirrors/electron/",
    [string]$PlaywrightHost = "https://npmmirror.com/mirrors/playwright/",
    [string]$GitMirror = "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/",
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
$env:PIP_INDEX_URL = $PypiMirror
$env:PIP_TRUSTED_HOST = ([System.Uri]$PypiMirror).Host
$env:UV_DEFAULT_INDEX = $PypiMirror
$env:UV_INDEX_URL = $PypiMirror

function Set-UserEnv {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, "User")
    Set-Item -Path "Env:$Name" -Value $Value
}

# Persist package mirrors for this install and future `hermes update` runs.
Set-UserEnv "npm_config_registry" $NpmRegistry
Set-UserEnv "NODEJS_ORG_MIRROR" $NodeMirror
Set-UserEnv "ELECTRON_MIRROR" $ElectronMirror
Set-UserEnv "PLAYWRIGHT_DOWNLOAD_HOST" $PlaywrightHost
Set-UserEnv "PIP_INDEX_URL" $PypiMirror
Set-UserEnv "PIP_TRUSTED_HOST" ([System.Uri]$PypiMirror).Host
Set-UserEnv "UV_DEFAULT_INDEX" $PypiMirror
Set-UserEnv "UV_INDEX_URL" $PypiMirror

# ============================================================================
# GitHub 代理链（国内可访问的 GitHub 反向代理，按优先级排列）
# 注意：代理稳定性不如镜像站，只有直连+镜像都不行的资源才走代理链
# ============================================================================
$GitHubProxies = @(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
)

# ============================================================================
# 工具函数
# ============================================================================
function Has-Command($name) { Get-Command $name -ErrorAction SilentlyContinue }
function Write-Step($m) { Write-Host "-> $m" -ForegroundColor Cyan }
function Write-OK($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "  [X] $m" -ForegroundColor Red }

# 通过代理链下载文件（直连 → gh-proxy.com → ghfast.top → 失败）
function Invoke-ProxyDownload {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)
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
Write-Host "  代理: GitHub 资源                  → ghfast/gh-proxy" -ForegroundColor Cyan
Write-Host "  直连: Hermes 官方脚本（raw.githubusercontent.com 国内可达）" -ForegroundColor Cyan
Write-Host ""

$hermesBin = "$env:LOCALAPPDATA\hermes\bin"
$managedHermesHome = "$env:LOCALAPPDATA\hermes"
New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null
$env:Path = "${hermesBin};${env:Path}"

function Add-UserPathEntry {
    param([string]$Entry)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $items = if ($current) { $current -split ";" } else { @() }
    if ($items -notcontains $Entry) {
        $items += $Entry
        [Environment]::SetEnvironmentVariable("Path", ($items -join ";"), "User")
    }
}

function Test-Node22 {
    param([string]$NodeExe)
    if ([string]::IsNullOrWhiteSpace($NodeExe)) { return $false }
    if (-not (Test-Path -LiteralPath $NodeExe)) { return $false }
    try {
        $version = & $NodeExe --version 2>$null
        $v = [version]($version -replace '^v', '')
        return (($v.Major -eq 20 -and $v.Minor -ge 19) -or ($v.Major -ge 22 -and ($v.Major -gt 22 -or $v.Minor -ge 12)))
    } catch { return $false }
}

function Install-ManagedNode {
    $nodeDir = "$managedHermesHome\node"
    $managedNode = "$nodeDir\node.exe"
    if (Test-Node22 $managedNode) {
        $env:Path = "$nodeDir;${env:Path}"
        Write-OK "已有 Hermes Node.js $((& $managedNode --version 2>$null))"
        return
    }
    $systemNode = Get-Command node -ErrorAction SilentlyContinue
    if ($systemNode -and (Test-Node22 $systemNode.Source)) {
        Write-OK "已有 Node.js $((node --version 2>$null))"
        return
    }

    Write-Step "从 npmmirror 安装 Node.js 22..."
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $index = Invoke-RestMethod -Uri "https://registry.npmmirror.com/-/binary/node/index.json" -TimeoutSec 60 -ErrorAction Stop
    $asset = $index | Where-Object { $_.version -match '^v22\.' } |
        Sort-Object { [version]($_.version -replace '^v', '') } -Descending | Select-Object -First 1
    if (-not $asset) { throw "npmmirror 中未找到 Node.js 22" }
    $zipName = "node-$($asset.version)-win-$arch.zip"
    $zipPath = "$env:TEMP\$zipName"
    $extractDir = "$env:TEMP\hermes-node-extract"
    Invoke-RestMethod -Uri "https://npmmirror.com/mirrors/node/$($asset.version)/$zipName" -OutFile $zipPath -TimeoutSec 300 -ErrorAction Stop
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $sourceDir = Get-ChildItem $extractDir -Directory | Select-Object -First 1
    if (-not $sourceDir -or -not (Test-Path "$($sourceDir.FullName)\node.exe")) { throw "Node.js 压缩包结构无效" }
    Remove-Item $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item $sourceDir.FullName $nodeDir
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Node22 $managedNode)) { throw "Node.js 安装后版本检查失败" }
    $env:Path = "$nodeDir;${env:Path}"
    Add-UserPathEntry $nodeDir
    Write-OK "Node.js $((& $managedNode --version 2>$null))（npmmirror）"
}

function Ensure-ManagedPython {
    Write-Step "检查 Python 3.11（由 uv 管理）..."
    # uv uses stderr and a non-zero exit code for the normal "not found"
    # probe. With EAP=Stop, PowerShell turns that expected result into a
    # terminating NativeCommandError before the install fallback can run.
    $installExitCode = 0
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $pythonPath = & uv python find 3.11 2>$null
    $findExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousEap
    if (-not $pythonPath) {
        Write-Step "未找到 Python 3.11，使用 uv 安装（npmmirror 镜像优先，无需代理）..."
        # 解释器下载（python-build-standalone）与 pip 包索引是两条链路：
        # npmmirror 有全量镜像，直连；失败再回退 GitHub 代理，最后官方直连。
        $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & uv python install 3.11 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        $installExitCode = $LASTEXITCODE
        if ($installExitCode -ne 0) {
            Write-Step "npmmirror 解释器镜像失败，回退 GitHub 代理..."
            $env:UV_PYTHON_INSTALL_MIRROR = "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"
            & uv python install 3.11 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            $installExitCode = $LASTEXITCODE
        }
        $ErrorActionPreference = $prev
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $pythonPath = & uv python find 3.11 2>$null
        $findExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousEap
    }
    if (-not $pythonPath) {
        throw "Python 3.11 安装或检测失败（uv find exit=$findExitCode，uv install exit=$installExitCode）"
    }
    Write-OK "Python $((& $pythonPath --version 2>$null))"
}

function Prepare-LocalHermesRepository {
    param([string]$InstallDir)
    if (Test-Path "$InstallDir\.git\HEAD") {
        Write-OK "已有 Hermes 源码仓库，交由官方脚本检查"
        return
    }

    Write-Step "通过 GitHub HTTPS 代理预先克隆 Hermes 源码..."
    $repoPath = "https://github.com/NousResearch/hermes-agent.git"
    $proxyUrls = @(
        "https://ghfast.top/$repoPath",
        "https://gh-proxy.com/$repoPath"
    )
    $previousEap = $ErrorActionPreference
    $cloneSuccess = $false
    try {
        $ErrorActionPreference = "Continue"
        foreach ($cloneUrl in $proxyUrls) {
            if ($cloneSuccess) { break }
            Write-Step "  尝试：$cloneUrl"
            if (Test-Path $InstallDir) {
                $backupDir = "$InstallDir.prepared-old-" + (Get-Date -Format "yyyyMMdd-HHmmss")
                Move-Item -LiteralPath $InstallDir -Destination $backupDir -ErrorAction Stop
                Write-Warn "已有不完整源码目录，已移到：$backupDir"
            }
            git -c windows.appendAtomically=false clone --depth 1 --branch main $cloneUrl $InstallDir 2>&1 |
                ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            if ($LASTEXITCODE -eq 0 -and (Test-Path "$InstallDir\.git\HEAD")) {
                $cloneSuccess = $true
                git -C $InstallDir config core.autocrlf false
                git -C $InstallDir remote set-url origin $cloneUrl
                Write-OK "Hermes 源码已通过代理克隆，保留完整 Git 信息"
            } else {
                Write-Warn "该代理克隆失败"
                if (Test-Path $InstallDir) {
                    $failedDir = "$InstallDir.clone-failed-" + (Get-Date -Format "yyyyMMdd-HHmmss")
                    Move-Item -LiteralPath $InstallDir -Destination $failedDir -ErrorAction SilentlyContinue
                }
            }
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
    if (-not $cloneSuccess) {
        throw "Hermes 源码通过 ghfast.top 和 gh-proxy.com 克隆均失败"
    }
}

function Ensure-RgFfmpeg {
    # ripgrep / ffmpeg 为可选能力。官方脚本检测到 rg/ffmpeg 已存在会跳过
    # winget 安装；这里从 GitHub 代理预下载，避免官方走 winget 直连失败。
    # 预装失败不阻断安装，官方脚本会自行降级或提示手动安装。
    $rgCmd = Get-Command rg -ErrorAction SilentlyContinue
    $ffCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($rgCmd -and $ffCmd) {
        Write-OK "已有 rg 和 ffmpeg"
        return
    }
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

    if (-not $rgCmd) {
        Write-Step "预装 ripgrep（GitHub 代理）..."
        $rgZip = "$env:TEMP\rg.zip"
        $rgExtract = "$env:TEMP\rg-extract"
        $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${arch}-pc-windows-msvc.zip"
        if ($arch -eq "x86") {
            $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-i686-pc-windows-msvc.zip"
        }
        if (Invoke-ProxyDownload -Url $rgUrl -OutFile $rgZip -TimeoutSec 180) {
            Remove-Item $rgExtract -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $rgZip -DestinationPath $rgExtract -Force
            $rgBin = Get-ChildItem $rgExtract -Recurse -Filter "rg.exe" | Select-Object -First 1
            if ($rgBin) {
                New-Item "$hermesBin\rg" -ItemType Directory -Force | Out-Null
                Copy-Item $rgBin.FullName "$hermesBin\rg\rg.exe" -Force
                $env:Path = "$hermesBin\rg;${env:Path}"
                Add-UserPathEntry "$hermesBin\rg"
                Write-OK "ripgrep $((& "$hermesBin\rg\rg.exe" --version 2>$null | Select-Object -First 1))"
            } else { Write-Warn "ripgrep 压缩包内未找到 rg.exe" }
        } else { Write-Warn "ripgrep 下载失败（跳过，官方会尝试 winget 或降级）" }
        Remove-Item $rgZip -Force -ErrorAction SilentlyContinue
        Remove-Item $rgExtract -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $ffCmd) {
        Write-Step "预装 ffmpeg（GitHub 代理）..."
        $ffZip = "$env:TEMP\ffmpeg.zip"
        $ffExtract = "$env:TEMP\ffmpeg-extract"
        $ffUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        if (Invoke-ProxyDownload -Url $ffUrl -OutFile $ffZip -TimeoutSec 300) {
            Remove-Item $ffExtract -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $ffZip -DestinationPath $ffExtract -Force
            $ffBin = Get-ChildItem $ffExtract -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
            if ($ffBin) {
                New-Item "$hermesBin\ffmpeg" -ItemType Directory -Force | Out-Null
                Copy-Item $ffBin.FullName "$hermesBin\ffmpeg\ffmpeg.exe" -Force
                $env:Path = "$hermesBin\ffmpeg;${env:Path}"
                Add-UserPathEntry "$hermesBin\ffmpeg"
                Write-OK "ffmpeg $((& "$hermesBin\ffmpeg\ffmpeg.exe" -version 2>$null | Select-Object -First 1))"
            } else { Write-Warn "ffmpeg 压缩包内未找到 ffmpeg.exe" }
        } else { Write-Warn "ffmpeg 下载失败（跳过，官方会尝试 winget 或降级）" }
        Remove-Item $ffZip -Force -ErrorAction SilentlyContinue
        Remove-Item $ffExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
        $sub = "$hermesBin\uv-${arch}-pc-windows-msvc"
        if (Test-Path "$sub\uv.exe") { Move-Item "$sub\uv.exe" "$hermesBin\uv.exe" -Force; Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue }
        elseif (-not (Test-Path "$hermesBin\uv.exe")) {
            $f = Get-ChildItem "$hermesBin\*.exe" -Recurse | Select-Object -First 1
            if ($f) { Copy-Item $f.FullName "$hermesBin\uv.exe" -Force }
        }
    } else { Write-Warn "uv 下载失败，Hermes 内置安装会尝试" }
    if (-not (Has-Command uv)) {
        Write-Err "uv 安装失败，无法继续。请检查网络或手动安装 uv"
        exit 1
    }
    Write-OK "uv $((uv --version 2>$null))"
}

# Python 运行时由 uv 管理；Python 包索引已通过 UV_DEFAULT_INDEX/PIP_INDEX_URL 配置。
# uv 下载 Python 运行时本身仍按官方渠道处理，不把 PyPI 镜像误当运行时镜像。

# ============================================================================
# 2. Git（清华 LatestRelease 镜像 → GitHub 代理备选）
# ============================================================================
$existingGitUsable = $false
$existingGit = Get-Command git -ErrorAction SilentlyContinue
if ($existingGit) {
    try {
        $gitCommandDir = Split-Path -Parent $existingGit.Source
        $gitRoot = Split-Path -Parent $gitCommandDir
        $existingBash = @(
            "$gitRoot\bin\bash.exe",
            "$gitRoot\usr\bin\bash.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $existingBash) { throw "未找到同一 Git 安装中的 bash.exe" }
        & $existingBash -lc "printf hermes-git-bash-ok" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Git Bash 兼容性检查失败" }
        $existingGitUsable = $true
        Write-OK "已有 Git $((git --version 2>$null))，Git Bash 可用"
    } catch {
        Write-Warn "PATH 中的 Git 不满足 Hermes 要求：$($_.Exception.Message)"
        Write-Warn "改用 Hermes 独立 PortableGit"
    }
}

if (-not $existingGitUsable) {
    Write-Step "下载 Git（清华镜像）..."
    $ok = $false

    $gitIndexUrl = "${GitMirror}LatestRelease/"
    $gitDir = "$hermesBin\git"
    $assetName = $null
    $tmpFile = $null

    try {
        $index = Invoke-RestMethod -Uri $gitIndexUrl -TimeoutSec 30 -ErrorAction Stop
        $assets = [regex]::Matches(
            [string]$index,
            'PortableGit-(\d+\.\d+\.\d+(?:\.\d+)?)-64-bit\.7z\.exe'
        )
        if ($assets.Count -gt 0) {
            $assetName = $assets[0].Value
        }
    } catch {
        Write-Warn "读取清华 LatestRelease 目录失败：$($_.Exception.Message)"
    }

    # LatestRelease 是清华提供的稳定目录别名。目录页暂时不可解析时，
    # 仍先尝试已验证的镜像文件，不应立即切换 GitHub 代理。
    if (-not $assetName) {
        $assetName = "PortableGit-2.55.0.3-64-bit.7z.exe"
        Write-Warn "未解析出最新版文件名，使用已验证镜像文件：$assetName"
    }
    $tmpFile = "$env:TEMP\$assetName"

    try {
        $gitDownloadUrl = "${gitIndexUrl}${assetName}"
        Write-Step "  $gitDownloadUrl"
        Invoke-RestMethod -Uri $gitDownloadUrl -OutFile $tmpFile -TimeoutSec 300 -ErrorAction Stop
        Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null

        # PortableGit 是自解压 7z 可执行文件，不是 ZIP，不能用 Expand-Archive。
        $extractProc = Start-Process -FilePath $tmpFile `
            -ArgumentList "-o`"$gitDir`"", "-y" `
            -NoNewWindow -Wait -PassThru
        if ($extractProc.ExitCode -ne 0) {
            throw "PortableGit 解压失败，退出码 $($extractProc.ExitCode)"
        }
        if (-not (Test-Path "$gitDir\cmd\git.exe")) { throw "缺少 cmd\git.exe" }
        if (-not (Test-Path "$gitDir\bin\bash.exe")) { throw "缺少 bin\bash.exe" }

        $env:Path = "$gitDir\cmd;$gitDir\bin;$gitDir\usr\bin;${env:Path}"
        $gitVersion = & "$gitDir\cmd\git.exe" --version 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git.exe 无法执行" }
        & "$gitDir\bin\bash.exe" -lc "printf hermes-git-bash-ok" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Git Bash 兼容性检查失败" }
        [Environment]::SetEnvironmentVariable("HERMES_GIT_BASH_PATH", "$gitDir\bin\bash.exe", "User")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $userPathItems = if ($userPath) { $userPath -split ";" } else { @() }
        foreach ($entry in @("$gitDir\cmd", "$gitDir\bin", "$gitDir\usr\bin")) {
            if ($userPathItems -notcontains $entry) { $userPathItems += $entry }
        }
        [Environment]::SetEnvironmentVariable("Path", ($userPathItems -join ";"), "User")
        $ok = $true
        Write-OK "$gitVersion（清华镜像，Git Bash 可用）"
    } catch {
        Write-Warn "清华镜像安装 Git 失败：$($_.Exception.Message)"
    } finally {
        if ($tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
    }

    # 只有清华镜像下载或解压确实失败后，才回退 GitHub 代理。
    if (-not $ok) {
        Write-Step "Git 尝试 GitHub 代理..."
        $assetName = "PortableGit-2.55.0.3-64-bit.7z.exe"
        $tmpFile = "$env:TEMP\$assetName"
        $fallbackUrl = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/$assetName"
        if (Invoke-ProxyDownload -Url $fallbackUrl -OutFile $tmpFile -TimeoutSec 300) {
            try {
                Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
                $extractProc = Start-Process -FilePath $tmpFile `
                    -ArgumentList "-o`"$gitDir`"", "-y" `
                    -NoNewWindow -Wait -PassThru
                if ($extractProc.ExitCode -ne 0) { throw "PortableGit 解压失败，退出码 $($extractProc.ExitCode)" }
                if (-not (Test-Path "$gitDir\cmd\git.exe")) { throw "缺少 cmd\git.exe" }
                if (-not (Test-Path "$gitDir\bin\bash.exe")) { throw "缺少 bin\bash.exe" }
                $env:Path = "$gitDir\cmd;$gitDir\bin;$gitDir\usr\bin;${env:Path}"
                $gitVersion = & "$gitDir\cmd\git.exe" --version 2>$null
                if ($LASTEXITCODE -ne 0) { throw "git.exe 无法执行" }
                & "$gitDir\bin\bash.exe" -lc "printf hermes-git-bash-ok" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git Bash 兼容性检查失败" }
                [Environment]::SetEnvironmentVariable("HERMES_GIT_BASH_PATH", "$gitDir\bin\bash.exe", "User")
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                $userPathItems = if ($userPath) { $userPath -split ";" } else { @() }
                foreach ($entry in @("$gitDir\cmd", "$gitDir\bin", "$gitDir\usr\bin")) {
                    if ($userPathItems -notcontains $entry) { $userPathItems += $entry }
                }
                [Environment]::SetEnvironmentVariable("Path", ($userPathItems -join ";"), "User")
                $ok = $true
                Write-OK "$gitVersion（GitHub 代理，Git Bash 可用）"
            } catch {
                Write-Warn "GitHub 代理包安装失败：$($_.Exception.Message)"
            } finally {
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not $ok) {
        Write-Err "Git 未能安装。Hermes 需要 Git 来安装源码。"
        Write-Err "请手动安装 Git：https://git-scm.com/download/win"
        exit 1
    }
}

# ============================================================================
# 3. 拉取 Hermes 官方安装脚本 → 原样执行
# ============================================================================
# 注意：raw.githubusercontent.com 在国内直连通常可达，此处先试直连再试代理
Write-Step "拉取 Hermes 安装脚本（直连优先）..."
$scriptUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1"
$script = $null

# 先试直连（国内通常可达）
try {
    $script = Invoke-RestMethod -Uri $scriptUrl -TimeoutSec 30 -ErrorAction Stop
    Write-Step "  直连成功"
} catch {
    Write-Warn "直连失败，走代理链..."
    $script = Invoke-ProxyText -Url $scriptUrl -TimeoutSec 60
}

if (-not $script) {
    Write-Err "无法下载 Hermes 安装脚本。请检查网络或使用离线安装包。"
    Write-Host "  离线安装请参考：https://github.com/q2026302/hermes-install-cn" -ForegroundColor Yellow
    exit 1
}

# The official script keeps repository clone URLs fixed and falls back to a
# GitHub ZIP archive when SSH/HTTPS clone is unavailable. We prepare a real
# Git clone before invoking it, so this archive rewrite is only a last-resort
# path if a later reinstall finds no usable repository.
$githubRepoProxy = "https://ghfast.top/"
$script = $script.Replace(
    'https://github.com/NousResearch/hermes-agent/archive/',
    "${githubRepoProxy}https://github.com/NousResearch/hermes-agent/archive/"
)

# 前置步骤校验：确认官方脚本会复用的依赖已装好。
if (-not (Has-Command uv)) {
    Write-Err "前置检查失败：uv 未安装"
    exit 1
}
if (-not (Has-Command git)) {
    Write-Err "前置检查失败：Git 未安装"
    Write-Err "请手动安装 Git：https://git-scm.com/download/win"
    exit 1
}

Install-ManagedNode
Ensure-ManagedPython
Prepare-LocalHermesRepository -InstallDir "$managedHermesHome\hermes-agent"
Ensure-RgFfmpeg

Write-Step "已准备好 uv、Git、Git Bash、Hermes 源码和可选工具，交由 Hermes 官方脚本继续安装"
Write-Step "执行 Hermes 官方安装脚本（不修改官方内容）..."
# 使用调用运算符在子作用域执行，避免官方脚本的参数变量
#（例如 HermesHome）覆盖本安装器自身变量。
$officialScriptBlock = [scriptblock]::Create([string]$script)
& $officialScriptBlock
$officialExitCode = $LASTEXITCODE
if ($officialExitCode -ne 0) {
    Write-Err "Hermes 官方安装脚本执行失败，退出码 $officialExitCode"
    exit 1
}

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  1. 重启终端（让 PATH 生效）" -ForegroundColor Cyan
Write-Host "  2. 输入 hermes 启动" -ForegroundColor Cyan
Write-Host "  3. 首次使用: hermes setup 配置 API Key" -ForegroundColor Cyan
Write-Host "  4. ffmpeg 为可选能力，核心安装完成后可再单独安装" -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Green
