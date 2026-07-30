# ============================================================================
# Hermes 离线安装包构建脚本
# 在一台能联网的 Windows 机器上运行，自动生成离线安装包
# 用法: .\build-package.ps1
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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$env:npm_config_registry = $NpmRegistry
$env:NODEJS_ORG_MIRROR = $NodeMirror
$env:ELECTRON_MIRROR = $ElectronMirror
$env:PLAYWRIGHT_DOWNLOAD_HOST = $PlaywrightHost

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = "$env:TEMP\hermes-build"
$OutputDir = "$RootDir\packages"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes 离线安装包构建工具                           |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta

# ============================================================================
# 1. 下载 uv
# ============================================================================
Write-Host "-> [1/8] 下载 uv..." -ForegroundColor Cyan
$arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
$uvDir = "$BuildDir\bin"
New-Item -ItemType Directory -Force -Path $uvDir | Out-Null
Invoke-RestMethod -Uri "${Mirror}https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip" -OutFile "$env:TEMP\uv.zip" -TimeoutSec 120
Expand-Archive "$env:TEMP\uv.zip" $uvDir -Force
if (Test-Path "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe") {
    Move-Item "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe" "$uvDir\uv.exe" -Force
    Remove-Item "$uvDir\uv-${arch}-pc-windows-msvc" -Recurse -Force -ErrorAction SilentlyContinue
}
$env:Path = "${uvDir};${env:Path}"
$uvVer = & "$uvDir\uv.exe" --version 2>$null
Write-Host "  [OK] $uvVer" -ForegroundColor Green

# ============================================================================
# 2. 下载 Portable Git
# ============================================================================
Write-Host "-> [2/8] 下载 Git..." -ForegroundColor Cyan
$gitDir = "$BuildDir\git"
try {
    Invoke-RestMethod -Uri "${Mirror}https://github.com/git-for-windows/git/releases/latest/download/PortableGit-2.48.1-64-bit.7z.exe" -OutFile "$env:TEMP\git.zip" -TimeoutSec 300
    Expand-Archive "$env:TEMP\git.zip" $gitDir -Force
    Write-Host "  [OK] Git" -ForegroundColor Green
} catch { Write-Host "  [!] Git 下载失败" -ForegroundColor Yellow }

# ============================================================================
# 3. 下载 Node.js
# ============================================================================
Write-Host "-> [3/8] 下载 Node.js..." -ForegroundColor Cyan
$nodeDir = "$BuildDir\node"
try {
    $nodeArch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $nodeUrl = "${NodeMirror}latest-v22.x/node-v22-win-${nodeArch}.zip"
    Invoke-RestMethod -Uri $nodeUrl -OutFile "$env:TEMP\node.zip" -TimeoutSec 300
    Expand-Archive "$env:TEMP\node.zip" "$BuildDir\node-extract" -Force
    $nodeFolder = Get-ChildItem "$BuildDir\node-extract" -Directory | Select-Object -First 1
    if ($nodeFolder) { Move-Item $nodeFolder.FullName $nodeDir -Force }
    Remove-Item "$BuildDir\node-extract" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Node.js" -ForegroundColor Green
} catch { Write-Host "  [!] Node.js 下载失败" -ForegroundColor Yellow }

# ============================================================================
# 4. 下载 ffmpeg
# ============================================================================
Write-Host "-> [4/8] 下载 ffmpeg..." -ForegroundColor Cyan
$ffmpegDir = "$BuildDir\ffmpeg"
try {
    Invoke-RestMethod -Uri "${Mirror}https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile "$env:TEMP\ffmpeg.zip" -TimeoutSec 300
    Expand-Archive "$env:TEMP\ffmpeg.zip" "$env:TEMP\ffmpeg-extract" -Force
    New-Item $ffmpegDir -ItemType Directory -Force | Out-Null
    $exe = Get-ChildItem "$env:TEMP\ffmpeg-extract" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    if ($exe) { Copy-Item $exe.FullName "$ffmpegDir\ffmpeg.exe" -Force }
    Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] ffmpeg" -ForegroundColor Green
} catch { Write-Host "  [!] ffmpeg 跳过" -ForegroundColor Yellow }

# ============================================================================
# 5. 克隆 Hermes 源码+检测版本
# ============================================================================
Write-Host "-> [5/8] 克隆 Hermes 源码..." -ForegroundColor Cyan
$hermesSrc = "$BuildDir\hermes-agent"
if (Test-Path $hermesSrc) { Remove-Item $hermesSrc -Recurse -Force }
git clone --depth 1 "${Mirror}https://github.com/NousResearch/hermes-agent.git" $hermesSrc 2>$null
if ($LASTEXITCODE -ne 0) {
    git clone --depth 1 "https://github.com/NousResearch/hermes-agent.git" $hermesSrc
}
$hermesVersion = "(unknown)"
$verFile = "$hermesSrc\hermes_cli\main.py"
if (Test-Path $verFile) {
    $verLine = (Get-Content $verFile -TotalCount 10) -match '^\d+\.\d+\.\d+' | Select-Object -First 1
    if ($verLine) { $hermesVersion = $verLine.Trim() }
}
Write-Host "  [OK] Hermes $hermesVersion" -ForegroundColor Green

# ============================================================================
# 6. 下载 Python 依赖（wheels）
# ============================================================================
Write-Host "-> [6/8] 下载 Python 依赖..." -ForegroundColor Cyan
$wheelsDir = "$BuildDir\wheels"
New-Item -ItemType Directory -Force -Path $wheelsDir | Out-Null
Push-Location $hermesSrc
& "$uvDir\uv.exe" venv "$env:TEMP\hermes-venv" --python-preference only-managed 2>$null
$env:VIRTUAL_ENV = "$env:TEMP\hermes-venv"
$env:Path = "$env:TEMP\hermes-venv\Scripts;${env:Path}"
& "$uvDir\uv.exe" pip download -r requirements.txt --destination $wheelsDir 2>$null
if ($LASTEXITCODE -ne 0) {
    & "$uvDir\uv.exe" pip download -r requirements.txt --destination $wheelsDir --index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/ 2>$null
}
Pop-Location
$wheelCount = (Get-ChildItem $wheelsDir -Filter "*.whl" | Measure-Object).Count
Write-Host "  [OK] $wheelCount wheels" -ForegroundColor Green

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
if (Test-Path "$OfflineDir\git\bin\git.exe") {
    $env:Path = "$OfflineDir\git\bin;${env:Path}"
    Write-Host "  [OK] Git" -ForegroundColor Green
}

# 3. Node.js
if (Test-Path "$OfflineDir\node\node.exe") {
    $env:Path = "$OfflineDir\node;${env:Path}"
    Write-Host "  [OK] Node.js" -ForegroundColor Green
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
uv venv --python-preference only-managed 2>$null
$env:VIRTUAL_ENV = "$hermesHome\hermes-agent\.venv"
$env:Path = "$hermesHome\hermes-agent\.venv\Scripts;${env:Path}"
Write-Host "  [OK]" -ForegroundColor Green

Write-Host "-> 安装 Python 依赖（离线）..." -ForegroundColor Cyan
uv pip install --no-index --find-links "$OfflineDir\wheels" -r requirements.txt 2>$null
if ($LASTEXITCODE -ne 0) {
    uv pip install --no-index --find-links "$OfflineDir\wheels" -r pyproject.toml 2>$null
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