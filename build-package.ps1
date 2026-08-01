# ============================================================================
# Hermes 离线安装包构建脚本
# 在一台能联网的 Windows 机器上运行，自动生成离线安装包
# 用法: .\build-package.ps1
#
# 镜像加速策略：
#   直连优先：清华镜像(npmmirror)下载 Node.js/npm
#   代理备用：GitHub Releases(uv/ffmpeg)走 gh-proxy
#   git clone Hermes 源码先直连，失败后走代理
# ============================================================================
param(
    [string]$Mirror = "https://gh-proxy.com/",
    [string]$NpmRegistry = "https://registry.npmmirror.com",
    [string]$NodeMirror = "https://npmmirror.com/mirrors/node/",
    [string]$ElectronMirror = "https://npmmirror.com/mirrors/electron/",
    [string]$PlaywrightHost = "https://npmmirror.com/mirrors/playwright/",
    [string]$GitMirror = "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/",
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"
if ($Proxy) { $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$env:npm_config_registry = $NpmRegistry
$env:NODEJS_ORG_MIRROR = $NodeMirror
$env:ELECTRON_MIRROR = $ElectronMirror
$env:PLAYWRIGHT_DOWNLOAD_HOST = $PlaywrightHost
$env:PIP_INDEX_URL = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/"
$env:PIP_TRUSTED_HOST = "mirrors.tuna.tsinghua.edu.cn"
$env:UV_DEFAULT_INDEX = $env:PIP_INDEX_URL
$env:UV_INDEX_URL = $env:PIP_INDEX_URL

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = "$env:TEMP\hermes-build"
$OutputDir = "$RootDir\packages"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes 离线安装包构建工具                           |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "  镜像: npm/Node → npmmirror" -ForegroundColor Cyan
Write-Host "  镜像: Git for Windows → 清华 mirrors" -ForegroundColor Cyan
Write-Host "  代理: uv/ffmpeg/Hermes源码 → ${Mirror}" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# 辅助：通过镜像或代理下载文件
# ============================================================================
function Invoke-WithMirror {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)
    # GitHub 资源先直连，失败后才使用代理。
    $attempts = @($Url)
    if ($Mirror -and $Url -match '^https://github\.com/') {
        $attempts += "${Mirror}${Url}"
    }
    foreach ($target in $attempts) {
        try {
            Invoke-RestMethod -Uri $target -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop
            return $true
        } catch { continue }
    }
    return $false
}

# ============================================================================
# 1. 下载 uv
# ============================================================================
Write-Host "-> [1/8] 下载 uv..." -ForegroundColor Cyan
$arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
$uvDir = "$BuildDir\bin"
New-Item -ItemType Directory -Force -Path $uvDir | Out-Null
$uvUrl = "https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip"
if (Invoke-WithMirror -Url $uvUrl -OutFile "$env:TEMP\uv.zip" -TimeoutSec 120) {
    Expand-Archive "$env:TEMP\uv.zip" $uvDir -Force
    if (Test-Path "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe") {
        Move-Item "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe" "$uvDir\uv.exe" -Force
        Remove-Item "$uvDir\uv-${arch}-pc-windows-msvc" -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:Path = "${uvDir};${env:Path}"
    $uvVer = & "$uvDir\uv.exe" --version 2>$null
    Write-Host "  [OK] $uvVer" -ForegroundColor Green
} else {
    Write-Host "  [X] uv 下载失败，离线包无法构建（uv 是核心依赖）" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 2. 下载 Portable Git
# ============================================================================
Write-Host "-> [2/8] 下载 Git..." -ForegroundColor Cyan
$gitDir = "$BuildDir\git"
try {
    $gitIndexUrl = "${GitMirror}LatestRelease/"
    $page = Invoke-RestMethod -Uri $gitIndexUrl -TimeoutSec 30 -ErrorAction Stop
    $assets = [regex]::Matches(
        [string]$page,
        'PortableGit-(\d+\.\d+\.\d+(?:\.\d+)?)-64-bit\.7z\.exe'
    )
    $assetName = $null
    if ($assets.Count -gt 0) {
        $assetName = $assets[0].Value
    }
    if (-not $assetName) {
        $assetName = "PortableGit-2.55.0.3-64-bit.7z.exe"
        Write-Host "  [!] 未解析出最新版，使用已验证镜像文件 ${assetName}" -ForegroundColor Yellow
    }
    $tmpGit = "$env:TEMP\$assetName"
    Invoke-RestMethod -Uri "${gitIndexUrl}${assetName}" -OutFile $tmpGit -TimeoutSec 300 -ErrorAction Stop
    Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
    $extractProc = Start-Process -FilePath $tmpGit `
        -ArgumentList "-o`"$gitDir`"", "-y" `
        -NoNewWindow -Wait -PassThru
    if ($extractProc.ExitCode -ne 0) { throw "PortableGit 解压失败，退出码 $($extractProc.ExitCode)" }
    if (-not (Test-Path "$gitDir\cmd\git.exe")) { throw "缺少 cmd\git.exe" }
    if (-not (Test-Path "$gitDir\bin\bash.exe")) { throw "缺少 bin\bash.exe" }
    $env:Path = "$gitDir\cmd;$gitDir\bin;$gitDir\usr\bin;${env:Path}"
    & "$gitDir\cmd\git.exe" --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git.exe 无法执行" }
    & "$gitDir\bin\bash.exe" -lc "printf hermes-git-bash-ok" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Git Bash 兼容性检查失败" }
    Write-Host "  [OK] Git (${assetName}, Git Bash 可用)" -ForegroundColor Green
} catch {
    Write-Host "  [!] 清华镜像安装失败：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  [!] 尝试 GitHub 代理..." -ForegroundColor Yellow
    try {
        $assetName = "PortableGit-2.55.0.3-64-bit.7z.exe"
        $tmpGit = "$env:TEMP\$assetName"
        $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/$assetName"
        if (-not (Invoke-WithMirror -Url $gitUrl -OutFile $tmpGit -TimeoutSec 300)) { throw "下载失败" }
        Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
        $extractProc = Start-Process -FilePath $tmpGit `
            -ArgumentList "-o`"$gitDir`"", "-y" `
            -NoNewWindow -Wait -PassThru
        if ($extractProc.ExitCode -ne 0) { throw "PortableGit 解压失败，退出码 $($extractProc.ExitCode)" }
        if (-not (Test-Path "$gitDir\cmd\git.exe")) { throw "缺少 cmd\git.exe" }
        if (-not (Test-Path "$gitDir\bin\bash.exe")) { throw "缺少 bin\bash.exe" }
        $env:Path = "$gitDir\cmd;$gitDir\bin;$gitDir\usr\bin;${env:Path}"
        & "$gitDir\bin\bash.exe" -lc "printf hermes-git-bash-ok" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Git Bash 兼容性检查失败" }
        Write-Host "  [OK] Git（GitHub 代理，Git Bash 可用）" -ForegroundColor Green
    } catch {
        Write-Host "  [X] Git 安装失败，无法继续：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} finally {
    if ($tmpGit) { Remove-Item $tmpGit -Force -ErrorAction SilentlyContinue }
}

# ============================================================================
# 3. 下载 Node.js
# ============================================================================
Write-Host "-> [3/8] 下载 Node.js..." -ForegroundColor Cyan
$nodeDir = "$BuildDir\node"
try {
    $nodeArch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    # npmmirror 目录页是动态渲染，直接查 index.json 获取最新 v22 版本号
    # （latest-v22.x/node-v22-win-x64.zip 这类通配文件名不存在）
    $index = Invoke-RestMethod -Uri "https://registry.npmmirror.com/-/binary/node/index.json" -TimeoutSec 60 -ErrorAction Stop
    $asset = $index | Where-Object { $_.version -match '^v22\.' } |
        Sort-Object { [version]($_.version -replace '^v', '') } -Descending | Select-Object -First 1
    if (-not $asset) { throw "npmmirror 中未找到 Node.js 22" }
    $zipName = "node-$($asset.version)-win-$nodeArch.zip"
    $nodeUrl = "https://npmmirror.com/mirrors/node/$($asset.version)/$zipName"
    Invoke-RestMethod -Uri $nodeUrl -OutFile "$env:TEMP\node.zip" -TimeoutSec 300 -ErrorAction Stop
    Expand-Archive "$env:TEMP\node.zip" "$BuildDir\node-extract" -Force
    $nodeFolder = Get-ChildItem "$BuildDir\node-extract" -Directory | Select-Object -First 1
    if ($nodeFolder) { Move-Item $nodeFolder.FullName $nodeDir -Force }
    Remove-Item "$BuildDir\node-extract" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Node.js $($asset.version)（npmmirror）" -ForegroundColor Green
} catch { Write-Host "  [!] Node.js 下载失败：$($_.Exception.Message)（浏览器工具将不可用，可稍后手动安装）" -ForegroundColor Yellow }

# ============================================================================
# 4. 下载 ffmpeg
# ============================================================================
Write-Host "-> [4/8] 下载 ffmpeg..." -ForegroundColor Cyan
$ffmpegDir = "$BuildDir\ffmpeg"
try {
    $ffmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    if (Invoke-WithMirror -Url $ffmpegUrl -OutFile "$env:TEMP\ffmpeg.zip" -TimeoutSec 300) {
        Expand-Archive "$env:TEMP\ffmpeg.zip" "$env:TEMP\ffmpeg-extract" -Force
        New-Item $ffmpegDir -ItemType Directory -Force | Out-Null
        $exe = Get-ChildItem "$env:TEMP\ffmpeg-extract" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
        if ($exe) { Copy-Item $exe.FullName "$ffmpegDir\ffmpeg.exe" -Force }
        Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] ffmpeg" -ForegroundColor Green
    } else { Write-Host "  [!] ffmpeg 下载失败" -ForegroundColor Yellow }
} catch { Write-Host "  [!] ffmpeg 跳过" -ForegroundColor Yellow }

# ============================================================================
# 4b. 下载 ripgrep（与在线安装 Ensure-RgFfmpeg 保持一致）
# ============================================================================
Write-Host "-> 下载 ripgrep..." -ForegroundColor Cyan
$rgDir = "$BuildDir\rg"
try {
    $rgArch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
    $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${rgArch}-pc-windows-msvc.zip"
    if (Invoke-WithMirror -Url $rgUrl -OutFile "$env:TEMP\rg.zip" -TimeoutSec 180) {
        Expand-Archive "$env:TEMP\rg.zip" "$env:TEMP\rg-extract" -Force
        New-Item $rgDir -ItemType Directory -Force | Out-Null
        $exe = Get-ChildItem "$env:TEMP\rg-extract" -Recurse -Filter "rg.exe" | Select-Object -First 1
        if ($exe) { Copy-Item $exe.FullName "$rgDir\rg.exe" -Force }
        Remove-Item "$env:TEMP\rg-extract" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] ripgrep 14.1.1" -ForegroundColor Green
    } else { Write-Host "  [!] ripgrep 下载失败" -ForegroundColor Yellow }
} catch { Write-Host "  [!] ripgrep 跳过" -ForegroundColor Yellow }

# ============================================================================
# 5. 克隆 Hermes 源码 + 检测版本
# ============================================================================
Write-Host "-> [5/8] 克隆 Hermes 源码..." -ForegroundColor Cyan
$hermesSrc = "$BuildDir\hermes-agent"
if (Test-Path $hermesSrc) { Remove-Item $hermesSrc -Recurse -Force }
# 先试直连，失败后才走代理。
git clone --depth 1 "https://github.com/NousResearch/hermes-agent.git" $hermesSrc 2>$null
if ($LASTEXITCODE -ne 0) {
    git clone --depth 1 "${Mirror}https://github.com/NousResearch/hermes-agent.git" $hermesSrc 2>$null
}
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$hermesSrc\pyproject.toml")) {
    Write-Host "  [X] Hermes 源码克隆失败，无法继续" -ForegroundColor Red
    exit 1
}
$hermesVersion = "(unknown)"
# 从 pyproject.toml 读取版本号（main.py 前 10 行不含版本）
$verFile = "$hermesSrc\pyproject.toml"
if (Test-Path $verFile) {
    $content = Get-Content $verFile
    $verLine = $content -match '^version\s*=\s*"(\d+\.\d+\.\d+)"' | Select-Object -First 1
    if ($verLine -match '(\d+\.\d+\.\d+)') { $hermesVersion = $Matches[1] }
}
Write-Host "  [OK] Hermes $hermesVersion" -ForegroundColor Green

# ============================================================================
# 6. 下载 Python 依赖（wheels）
# ============================================================================
Write-Host "-> [6/8] 下载 Python 依赖..." -ForegroundColor Cyan
$wheelsDir = "$BuildDir\wheels"
New-Item -ItemType Directory -Force -Path $wheelsDir | Out-Null
Push-Location $hermesSrc
if (Test-Path "$uvDir\uv.exe") {
    & "$uvDir\uv.exe" venv "$env:TEMP\hermes-venv" --python 3.11 --python-preference only-managed 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] Python 3.11 虚拟环境创建失败" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    $env:VIRTUAL_ENV = "$env:TEMP\hermes-venv"
    $env:Path = "$env:TEMP\hermes-venv\Scripts;${env:Path}"
    # 先试清华 PyPI 镜像（直连）
    & "$uvDir\uv.exe" pip download -r requirements.txt --destination $wheelsDir --index-url $env:PIP_INDEX_URL 2>$null
    if ((Get-ChildItem $wheelsDir -Filter "*.whl" | Measure-Object).Count -eq 0) {
        Write-Host "  [X] 从清华 PyPI 下载 Python 依赖失败" -ForegroundColor Red
        Pop-Location
        exit 1
    }
} else {
    Write-Host "  [!] uv 未下载，跳过 Python 依赖" -ForegroundColor Yellow
}
Pop-Location
$wheelCount = (Get-ChildItem $wheelsDir -Filter "*.whl" | Measure-Object).Count
Write-Host "  [OK] $wheelCount wheels" -ForegroundColor Green

# ============================================================================
# 6b. 打包 Python 3.11 运行时（离线机器无法联网下载解释器）
# ============================================================================
Write-Host "-> 打包 Python 3.11 运行时..." -ForegroundColor Cyan
$pyInstallBase = "$env:LOCALAPPDATA\uv\python"
$pyRuntimeDir = $null
if (Test-Path $pyInstallBase) {
    $pyRuntimeDir = Get-ChildItem $pyInstallBase -Directory -Filter "cpython-3.11*" |
        Sort-Object Name -Descending | Select-Object -First 1
}
if (-not $pyRuntimeDir) {
    # uv venv 已在上一步创建，理论上解释器必然存在；万一没有则尝试补装
    & "$uvDir\uv.exe" python install 3.11 2>&1 | Out-Null
    if (Test-Path $pyInstallBase) {
        $pyRuntimeDir = Get-ChildItem $pyInstallBase -Directory -Filter "cpython-3.11*" |
            Sort-Object Name -Descending | Select-Object -First 1
    }
}
if ($pyRuntimeDir) {
    New-Item "$BuildDir\python" -ItemType Directory -Force | Out-Null
    Copy-Item $pyRuntimeDir.FullName "$BuildDir\python\" -Recurse -Force
    Write-Host "  [OK] Python 运行时 $($pyRuntimeDir.Name)" -ForegroundColor Green
} else {
    Write-Host "  [X] 未找到 uv 管理的 Python 3.11 运行时，离线包无法构建" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 7. 下载 npm 缓存
# ============================================================================
Write-Host "-> [7/8] 下载 npm 依赖..." -ForegroundColor Cyan
$npmCacheDir = "$BuildDir\npm-cache"
New-Item -ItemType Directory -Force -Path $npmCacheDir | Out-Null
Push-Location $hermesSrc
if (Test-Path "$nodeDir\node.exe") {
    $env:Path = "$nodeDir;${env:Path}"
}
npm install --prefer-offline --cache $npmCacheDir 2>$null
if ($LASTEXITCODE -ne 0) {
    npm install --cache $npmCacheDir 2>$null
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] npm 依赖安装失败" -ForegroundColor Red
    exit 1
}
Pop-Location
Write-Host "  [OK] npm cache" -ForegroundColor Green

# ============================================================================
# 8. 打包
# ============================================================================
Write-Host "-> [8/8] 打包离线安装包..." -ForegroundColor Cyan

# 构建目录结构
$PkgDir = "$BuildDir\hermes-install-cn-v${hermesVersion}"
New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null

# 复制二进制
Copy-Item "$BuildDir\bin" "$PkgDir\" -Recurse -Force
if (Test-Path $gitDir) { Copy-Item $gitDir "$PkgDir\" -Recurse -Force }
if (Test-Path $nodeDir) { Copy-Item $nodeDir "$PkgDir\" -Recurse -Force }
if (Test-Path $ffmpegDir) { Copy-Item $ffmpegDir "$PkgDir\" -Recurse -Force }
if (Test-Path $rgDir) { Copy-Item $rgDir "$PkgDir\" -Recurse -Force }
if (Test-Path "$BuildDir\python") { Copy-Item "$BuildDir\python" "$PkgDir\" -Recurse -Force }

# 复制 Hermes 源码
Copy-Item $hermesSrc "$PkgDir\hermes-agent" -Recurse -Force
Remove-Item "$PkgDir\hermes-agent\.git" -Recurse -Force -ErrorAction SilentlyContinue

# 复制依赖缓存
Copy-Item $wheelsDir "$PkgDir\" -Recurse -Force
Copy-Item $npmCacheDir "$PkgDir\" -Recurse -Force

# 复制离线安装脚本
$offlineScript = @'
# ============================================================================
# Hermes Agent 离线安装脚本
# 放在离线安装包根目录，解压后直接运行
# ============================================================================
$OfflineDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hermesBin = "$env:LOCALAPPDATA\hermes\bin"
$hermesHome = "$env:LOCALAPPDATA\hermes"

# Keep package managers on domestic mirrors for any online fallback/update.
$env:npm_config_registry = "https://registry.npmmirror.com"
$env:NODEJS_ORG_MIRROR = "https://npmmirror.com/mirrors/node/"
$env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
$env:PLAYWRIGHT_DOWNLOAD_HOST = "https://npmmirror.com/mirrors/playwright/"
$env:PIP_INDEX_URL = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/"
$env:PIP_TRUSTED_HOST = "mirrors.tuna.tsinghua.edu.cn"
$env:UV_DEFAULT_INDEX = $env:PIP_INDEX_URL
$env:UV_INDEX_URL = $env:PIP_INDEX_URL

New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null
$env:Path = "${hermesBin};${env:Path}"

Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes Agent 离线安装                                |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta

# 1. uv
$uvDir = "$OfflineDir\bin"
Copy-Item "$uvDir\uv.exe" "$hermesBin\uv.exe" -Force
Write-Host "  [OK] uv" -ForegroundColor Green

# 2. Git
$gitSource = "$OfflineDir\git"
$gitTarget = "$hermesHome\git"
if (-not (Test-Path "$gitSource\cmd\git.exe")) {
    Write-Host "  [X] 离线包缺少 git\cmd\git.exe" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$gitSource\bin\bash.exe")) {
    Write-Host "  [X] 离线包缺少 git\bin\bash.exe" -ForegroundColor Red
    exit 1
}
Remove-Item $gitTarget -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $gitSource $gitTarget -Recurse -Force
$gitPathEntries = @(
    "$gitTarget\cmd",
    "$gitTarget\bin",
    "$gitTarget\usr\bin"
)
$env:Path = "$(($gitPathEntries -join ';'));${env:Path}"
& "$gitTarget\bin\bash.exe" -lc "printf hermes-git-bash-ok" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] Git Bash 兼容性检查失败" -ForegroundColor Red
    exit 1
}
[Environment]::SetEnvironmentVariable("HERMES_GIT_BASH_PATH", "$gitTarget\bin\bash.exe", "User")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$userPathItems = if ($userPath) { $userPath -split ";" } else { @() }
foreach ($entry in $gitPathEntries) {
    if ($userPathItems -notcontains $entry) { $userPathItems += $entry }
}
[Environment]::SetEnvironmentVariable("Path", ($userPathItems -join ";"), "User")
Write-Host "  [OK] Git + Git Bash" -ForegroundColor Green

# 3. Node.js
if (Test-Path "$OfflineDir\node\node.exe") {
    $env:Path = "$OfflineDir\node;${env:Path}"
    Write-Host "  [OK] Node.js" -ForegroundColor Green
}

# 3b. ripgrep
if (Test-Path "$OfflineDir\rg\rg.exe") {
    New-Item "$hermesBin\rg" -ItemType Directory -Force | Out-Null
    Copy-Item "$OfflineDir\rg\rg.exe" "$hermesBin\rg\rg.exe" -Force
    $env:Path = "$hermesBin\rg;${env:Path}"
    Write-Host "  [OK] ripgrep" -ForegroundColor Green
}

# 3c. Python 3.11 运行时（放到 uv 默认 Python 安装目录，uv 自动发现）
if (Test-Path "$OfflineDir\python") {
    $uvPythonDir = "$env:LOCALAPPDATA\uv\python"
    New-Item -ItemType Directory -Force -Path $uvPythonDir | Out-Null
    Copy-Item "$OfflineDir\python\*" $uvPythonDir -Recurse -Force
    Write-Host "  [OK] Python 3.11 运行时" -ForegroundColor Green
}

# 4. ffmpeg
if (Test-Path "$OfflineDir\ffmpeg\ffmpeg.exe") {
    $env:Path = "$OfflineDir\ffmpeg;${env:Path}"
    Write-Host "  [OK] ffmpeg" -ForegroundColor Green
}

# 5. Hermes 源码
Write-Host "-> 部署 Hermes 源码..." -ForegroundColor Cyan
Copy-Item "$OfflineDir\hermes-agent" "$hermesHome\hermes-agent" -Recurse -Force
Write-Host "  [OK]" -ForegroundColor Green

# 6. 创建 venv + 安装依赖
Push-Location "$hermesHome\hermes-agent"
Write-Host "-> 创建 Python 虚拟环境..." -ForegroundColor Cyan
uv venv --python 3.11 --python-preference only-managed 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] Python 虚拟环境创建失败（缺少 Python 3.11 运行时？）" -ForegroundColor Red
    exit 1
}
$env:VIRTUAL_ENV = "$hermesHome\hermes-agent\.venv"
$env:Path = "$hermesHome\hermes-agent\.venv\Scripts;${env:Path}"
Write-Host "  [OK]" -ForegroundColor Green

Write-Host "-> 安装 Python 依赖（离线）..." -ForegroundColor Cyan
uv pip install --no-index --find-links "$OfflineDir\wheels" -r requirements.txt 2>$null
if ($LASTEXITCODE -ne 0) {
    uv pip install --no-index --find-links "$OfflineDir\wheels" -r pyproject.toml 2>$null
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] Python 依赖安装失败" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK]" -ForegroundColor Green
Pop-Location

# 7. npm install（离线）
Push-Location "$hermesHome\hermes-agent"
if (Test-Path "$OfflineDir\node\node.exe") {
    Write-Host "-> 安装 Node.js 依赖（离线）..." -ForegroundColor Cyan
    npm install --offline --cache "$OfflineDir\npm-cache" 2>$null
    if ($LASTEXITCODE -ne 0) {
        npm install --cache "$OfflineDir\npm-cache" 2>$null
    }
    Write-Host "  [OK]" -ForegroundColor Green
}
Pop-Location

Write-Host "`n[OK] 安装完成！重启终端后输入 hermes 即可使用。" -ForegroundColor Green
'@

$offlineScript | Out-File -FilePath "$PkgDir\install-offline.ps1" -Encoding utf8

# 压缩
$packageFile = "$OutputDir\hermes-install-cn-v${hermesVersion}.zip"
if (Test-Path $packageFile) { Remove-Item $packageFile -Force }
Compress-Archive -Path "$PkgDir\*" -DestinationPath $packageFile

# 清理临时文件
Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue

$pkgSize = "{0:N1}" -f ((Get-Item $packageFile).Length / 1MB)
Write-Host "`n[OK] 离线包已生成: $packageFile ($pkgSize MB)" -ForegroundColor Green
Write-Host "Hermes 版本: $hermesVersion" -ForegroundColor Cyan
Write-Host "上传到 Gitee Releases 或百度网盘即可分发。" -ForegroundColor Yellow
