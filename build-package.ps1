# ============================================================================
# Hermes 离线安装包构建脚本
# 在一台能联网的 Windows 机器上运行，自动生成离线安装包
# 用法: .\build-package.ps1
#
# 版本策略：Hermes 各版本的依赖要求不同（如 node 门槛 22→26），
# 默认锁定 release tag（-HermesVersion 可覆盖，如 v2026.7.30 / master）。
#
# 增量构建：已下载的组件缓存在 cache\build\ 下，重复运行或网络中断后
# 重跑会自动复用已有成果，只补缺失部分。加 -Force 强制全量重建。
#
# 镜像加速策略：
#   直连优先：清华镜像(npmmirror)下载 Node.js/npm
#   代理备用：GitHub Releases(uv/ffmpeg)走 gh-proxy
#   git clone Hermes 源码先直连，失败后走代理
# ============================================================================
param(
    [switch]$Force,
    [string]$HermesVersion = "v2026.7.30",
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
# 固定缓存目录（不再使用 TEMP）：断点续建、复用已有下载成果
$BuildDir = "$RootDir\cache\build"
$OutputDir = "$RootDir\packages"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# 脚本版本：显示在 banner 标题行，运行时可核对是否最新
$scriptVersion = "v6"

if ($Force) {
    Write-Host "  [ -Force ] 清空构建缓存，全量重建..." -ForegroundColor Yellow
    Get-ChildItem $BuildDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes 离线安装包构建工具 v6                       |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "  镜像: npm/Node → npmmirror" -ForegroundColor Cyan
Write-Host "  镜像: Git for Windows → 清华 mirrors" -ForegroundColor Cyan
Write-Host "  代理: uv/ffmpeg/Hermes源码 → ${Mirror}" -ForegroundColor Cyan
Write-Host "  缓存: $BuildDir （已有组件自动复用）" -ForegroundColor DarkGray
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

# 包装原生命令（git/npm/uv）：PowerShell 5.1 在 EAP=Stop 下会把原生命令
# 写入 stderr 的正常输出（git 的 "Cloning into..."、npm/uv 的进度信息）
# 当成致命错误抛出。临时放宽 EAP，吞掉 stdout+stderr，只返回真实退出码。
function Invoke-NativeChecked {
    param([scriptblock]$ScriptBlock)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & $ScriptBlock 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return $code
}

# ============================================================================
# 1. 下载 uv
# ============================================================================
Write-Host "-> [1/8] 下载 uv..." -ForegroundColor Cyan
$arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
$uvDir = "$BuildDir\bin"
New-Item -ItemType Directory -Force -Path $uvDir | Out-Null
if (Test-Path "$uvDir\uv.exe") {
    Write-Host "  [OK] 已有 uv $((& "$uvDir\uv.exe" --version 2>$null))，跳过下载" -ForegroundColor Green
} else {
    $uvUrl = "https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-pc-windows-msvc.zip"
    if (Invoke-WithMirror -Url $uvUrl -OutFile "$env:TEMP\uv.zip" -TimeoutSec 120) {
        Expand-Archive "$env:TEMP\uv.zip" $uvDir -Force
        if (Test-Path "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe") {
            Move-Item "$uvDir\uv-${arch}-pc-windows-msvc\uv.exe" "$uvDir\uv.exe" -Force
            Remove-Item "$uvDir\uv-${arch}-pc-windows-msvc" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item "$env:TEMP\uv.zip" -Force -ErrorAction SilentlyContinue
        $uvVer = & "$uvDir\uv.exe" --version 2>$null
        Write-Host "  [OK] $uvVer" -ForegroundColor Green
    } else {
        Write-Host "  [X] uv 下载失败，离线包无法构建（uv 是核心依赖）" -ForegroundColor Red
        exit 1
    }
}
$env:Path = "${uvDir};${env:Path}"

# ============================================================================
# 2. 下载 Portable Git
# 策略：下载自解压 .7z.exe 解压验证后，打包成 git.tar（单个文件，无碎文件）。
# 构建时保留 $gitDir 供克隆源码用；进包/分发只带 git.tar，离线安装时 tar -xf。
# ============================================================================
Write-Host "-> [2/8] 下载 Git..." -ForegroundColor Cyan
$gitDir = "$BuildDir\git"
$gitTar = "$BuildDir\git.tar"
$tarExe = "$env:SystemRoot\System32\tar.exe"
$gitCachedOk = $false
if (Test-Path $gitTar) {
    # git.tar 已缓存：需要 git.exe 时从 tar 恢复目录
    if (-not (Test-Path "$gitDir\cmd\git.exe")) {
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
        & $tarExe -xf $gitTar -C $gitDir 2>&1 | Out-Null
    }
    if (Test-Path "$gitDir\cmd\git.exe") {
        $env:Path = "$gitDir\cmd;$gitDir\bin;$gitDir\usr\bin;${env:Path}"
        $gitCachedOk = $true
    }
}
if (-not $gitCachedOk) {
    if (Test-Path $gitDir) { Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue }
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
    # 打包成单个 git.tar（无压缩，秒级），进包/分发用
    # 必须用 Windows 自带 tar.exe：Git Bash 的 /usr/bin/tar 会把 "C:" 当远程主机
    Remove-Item $gitTar -Force -ErrorAction SilentlyContinue
    & $tarExe -cf $gitTar -C $gitDir .
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $gitTar)) { throw "git.tar 打包失败" }
    Write-Host "  [OK] Git (${assetName}, Git Bash 可用, 已打包 git.tar)" -ForegroundColor Green
} catch {
    Write-Host "  [!] 清华镜像安装失败：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  [!] 尝试 GitHub 代理..." -ForegroundColor Yellow
    try {
        $assetName = "PortableGit-2.55.0.3-64-bit.7z.exe"
        $tmpGit = "$env:TEMP\$assetName"
        $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/$assetName"
        if (-not (Invoke-WithMirror -Url $gitUrl -OutFile $tmpGit -TimeoutSec 300)) { throw "下载失败" }
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
        Remove-Item $gitTar -Force -ErrorAction SilentlyContinue
        & $tarExe -cf $gitTar -C $gitDir .
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $gitTar)) { throw "git.tar 打包失败" }
        Write-Host "  [OK] Git（GitHub 代理，已打包 git.tar）" -ForegroundColor Green
    } catch {
        Write-Host "  [X] Git 安装失败，无法继续：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    } finally {
        if ($tmpGit) { Remove-Item $tmpGit -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "  [OK] 已有 Git $((& "$gitDir\cmd\git.exe" --version 2>$null))，跳过下载" -ForegroundColor Green
}

# ============================================================================
# 3. 下载 Node.js
# 策略：保留原始 node.zip（单个文件，不碎）。构建时需要 node.exe 跑 npm 时
# 才解压到 $nodeDir（本地缓存）；进包/分发只带 node.zip，离线安装时再解压。
# ============================================================================
Write-Host "-> [3/8] 下载 Node.js..." -ForegroundColor Cyan
$nodeDir = "$BuildDir\node"
$nodeZip = "$BuildDir\node.zip"
$nodeCachedOk = $false
if (Test-Path $nodeZip) {
    $nodeCachedOk = $true
    Write-Host "  [OK] 已有 node.zip，跳过下载" -ForegroundColor Green
}
if (-not $nodeCachedOk) {
try {
    $nodeArch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    # npmmirror 目录页是动态渲染，直接查 index.json 获取最新 v26 版本号
    # （Hermes 0.19.1 要求 node>=26.0.0, npm>=12.0.0；v22 已不满足）
    $index = Invoke-RestMethod -Uri "https://registry.npmmirror.com/-/binary/node/index.json" -TimeoutSec 60 -ErrorAction Stop
    $asset = $index | Where-Object { $_.version -match '^v26\.' } |
        Sort-Object { [version]($_.version -replace '^v', '') } -Descending | Select-Object -First 1
    if (-not $asset) { throw "npmmirror 中未找到 Node.js 26" }
    $zipName = "node-$($asset.version)-win-$nodeArch.zip"
    $nodeUrl = "https://npmmirror.com/mirrors/node/$($asset.version)/$zipName"
    Invoke-RestMethod -Uri $nodeUrl -OutFile "$env:TEMP\node.zip" -TimeoutSec 300 -ErrorAction Stop
    # 验证 zip 有效（解压出 node.exe 即算过），验证后删除目录只留 zip
    Remove-Item "$BuildDir\node-verify" -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive "$env:TEMP\node.zip" "$BuildDir\node-verify" -Force
    $nodeFolder = Get-ChildItem "$BuildDir\node-verify" -Directory | Select-Object -First 1
    if (-not $nodeFolder -or -not (Test-Path "$($nodeFolder.FullName)\node.exe")) { throw "Node.js 压缩包结构无效" }
    Remove-Item "$BuildDir\node-verify" -Recurse -Force
    Remove-Item $nodeZip -Force -ErrorAction SilentlyContinue
    Move-Item "$env:TEMP\node.zip" $nodeZip
    Write-Host "  [OK] Node.js $($asset.version)（npmmirror，已存 node.zip）" -ForegroundColor Green
} catch { Write-Host "  [!] Node.js 下载失败：$($_.Exception.Message)（浏览器工具将不可用，可稍后手动安装）" -ForegroundColor Yellow }
}
# npm 段需要 node.exe：确保解压出 $nodeDir（本地缓存目录）
if (Test-Path $nodeZip) {
    if (-not (Test-Path "$nodeDir\node.exe")) {
        Remove-Item $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$BuildDir\node-extract" -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $nodeZip "$BuildDir\node-extract" -Force
        $nodeFolder = Get-ChildItem "$BuildDir\node-extract" -Directory | Select-Object -First 1
        if ($nodeFolder) { Move-Item $nodeFolder.FullName $nodeDir -Force }
        Remove-Item "$BuildDir\node-extract" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# 4. 下载 ffmpeg
# ============================================================================
Write-Host "-> [4/8] 下载 ffmpeg..." -ForegroundColor Cyan
$ffmpegDir = "$BuildDir\ffmpeg"
if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    Write-Host "  [OK] 已有 ffmpeg，跳过下载" -ForegroundColor Green
} else {
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
}

# ============================================================================
# 4b. 下载 ripgrep（与在线安装 Ensure-RgFfmpeg 保持一致）
# ============================================================================
Write-Host "-> 下载 ripgrep..." -ForegroundColor Cyan
$rgDir = "$BuildDir\rg"
if (Test-Path "$rgDir\rg.exe") {
    Write-Host "  [OK] 已有 ripgrep $((& "$rgDir\rg.exe" --version 2>$null | Select-Object -First 1))，跳过下载" -ForegroundColor Green
} else {
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
}

# ============================================================================
# 5. 克隆 Hermes 源码 + 检测版本
# ============================================================================
Write-Host "-> [5/8] 克隆 Hermes 源码（锁定 $HermesVersion）..." -ForegroundColor Cyan
$hermesSrc = "$BuildDir\hermes-agent"
$hermesRepo = "https://github.com/NousResearch/hermes-agent.git"
$hermesRepoMirror = "${Mirror}$hermesRepo"
if (Test-Path "$hermesSrc\.git") {
    # 已有快照：切到指定版本（tag），不再跟随 master。
    # 直连 fetch → 代理 fetch 兜底；失败不阻断，保留旧快照继续。
    Write-Host "  [~] 已有 Hermes 源码，切到 $HermesVersion..." -ForegroundColor Cyan
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git -C $hermesSrc fetch --depth 1 origin tag $HermesVersion 2>&1 | Out-Null
    $updateRc = $LASTEXITCODE
    if ($updateRc -eq 0) {
        git -C $hermesSrc checkout --force $HermesVersion 2>&1 | Out-Null
        $updateRc = $LASTEXITCODE
    }
    if ($updateRc -ne 0) {
        git -C $hermesSrc fetch --depth 1 "$hermesRepoMirror" tag $HermesVersion 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            git -C $hermesSrc checkout --force FETCH_HEAD 2>&1 | Out-Null
            $updateRc = $LASTEXITCODE
        }
    }
    $ErrorActionPreference = $prevEap
    if ($updateRc -eq 0) {
        Write-Host "  [OK] Hermes 源码已就位（$HermesVersion）" -ForegroundColor Green
    } else {
        Write-Host "  [!] 切换 $HermesVersion 失败（网络问题），使用缓存快照继续打包" -ForegroundColor Yellow
    }
} else {
    if (Test-Path $hermesSrc) { Remove-Item $hermesSrc -Recurse -Force }
    # 锁定版本克隆（直连 → 代理）。指定 master 时才克隆主分支。
    $cloneRef = if ($HermesVersion -eq "master") { $HermesVersion } else { "tag $HermesVersion" }
    $cloneRc = Invoke-NativeChecked { git clone --depth 1 --branch $HermesVersion $hermesRepo $hermesSrc }
    if ($cloneRc -ne 0) {
        $cloneRc = Invoke-NativeChecked { git clone --depth 1 --branch $HermesVersion $hermesRepoMirror $hermesSrc }
    }
    if ($cloneRc -ne 0 -or -not (Test-Path "$hermesSrc\pyproject.toml")) {
        Write-Host "  [X] Hermes 源码克隆失败（$HermesVersion），无法继续" -ForegroundColor Red
        exit 1
    }
}
$hermesVersion = $HermesVersion.TrimStart('v')

# ============================================================================
# 6. 下载 Python 依赖（wheels）
# ============================================================================
Write-Host "-> [6/8] 下载 Python 依赖..." -ForegroundColor Cyan
$wheelsDir = "$BuildDir\wheels"
New-Item -ItemType Directory -Force -Path $wheelsDir | Out-Null
$existingWheels = @(Get-ChildItem $wheelsDir -Filter "*.whl" -ErrorAction SilentlyContinue)
if ($existingWheels.Count -gt 0) {
    Write-Host "  [OK] 已有 $($existingWheels.Count) 个 wheels，跳过下载" -ForegroundColor Green
} else {
Push-Location $hermesSrc
if (Test-Path "$uvDir\uv.exe") {
    # 确保 uv 管理的 Python 3.11 可用：本地没有则联网下载。
    # 注意 UV_DEFAULT_INDEX 只影响 pip 包索引，解释器下载是另一条链路
    # （python-build-standalone）。国内优先走 npmmirror 全量镜像（无需代理），
    # 失败再回退 GitHub 代理，最后官方直连。
    $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
    $pyInstallRc = Invoke-NativeChecked { & "$uvDir\uv.exe" python install 3.11 }
    if ($pyInstallRc -ne 0) {
        Write-Host "  [!] npmmirror 解释器镜像失败，回退 GitHub 代理..." -ForegroundColor Yellow
        $env:UV_PYTHON_INSTALL_MIRROR = "${Mirror}https://github.com/astral-sh/python-build-standalone/releases/download"
        $pyInstallRc = Invoke-NativeChecked { & "$uvDir\uv.exe" python install 3.11 }
    }
    if ($pyInstallRc -ne 0) {
        Write-Host "  [!] 代理也失败，最后尝试官方直连..." -ForegroundColor Yellow
        Remove-Item Env:UV_PYTHON_INSTALL_MIRROR -ErrorAction SilentlyContinue
        $pyInstallRc = Invoke-NativeChecked { & "$uvDir\uv.exe" python install 3.11 }
    }
    $pyFindRc = Invoke-NativeChecked { & "$uvDir\uv.exe" python find 3.11 }
    if ($pyFindRc -ne 0) {
        Write-Host "  [X] Python 3.11 不可用（install exit=$pyInstallRc, find exit=$pyFindRc），详情：" -ForegroundColor Red
        & "$uvDir\uv.exe" python find 3.11 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        Pop-Location
        exit 1
    }
    # --clear：清掉上次失败残留的半成品 venv（uv 默认目录已存在会报错）
    $venvRc = Invoke-NativeChecked { & "$uvDir\uv.exe" venv "$env:TEMP\hermes-venv" --python 3.11 --python-preference only-managed --clear }
    if ($venvRc -ne 0) {
        Write-Host "  [X] Python 3.11 虚拟环境创建失败（exit=$venvRc），详情：" -ForegroundColor Red
        $prevEap2 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & "$uvDir\uv.exe" venv "$env:TEMP\hermes-venv" --python 3.11 --python-preference only-managed --clear 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        $ErrorActionPreference = $prevEap2
        Pop-Location
        exit 1
    }
    $env:VIRTUAL_ENV = "$env:TEMP\hermes-venv"
    $env:Path = "$env:TEMP\hermes-venv\Scripts;${env:Path}"
    $pyExe = "$env:TEMP\hermes-venv\Scripts\python.exe"
    # Hermes 无 requirements.txt：用内置 tomllib 从 pyproject.toml 提取
    # [project].dependencies（== 精确 pin）；pip download 会自行解析传递依赖。
    # （pip 不支持 -r pyproject.toml，uv pip 也没有 download 子命令）
    $depFile = "$env:TEMP\hermes-requirements.txt"
    if (Test-Path "$hermesSrc\requirements.txt") {
        Copy-Item "$hermesSrc\requirements.txt" $depFile -Force
    } else {
        $extractPy = "$env:TEMP\extract-hermes-deps.py"
        @'
import tomllib, sys
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
deps = data.get("project", {}).get("dependencies", [])
for d in deps:
    print(d)
'@ | Out-File -FilePath $extractPy -Encoding ascii
        $prevEap3 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $deps = & $pyExe $extractPy "$hermesSrc\pyproject.toml" 2>$null
        $ErrorActionPreference = $prevEap3
        if (-not $deps) {
            Write-Host "  [X] 无法从 pyproject.toml 提取依赖" -ForegroundColor Red
            Pop-Location
            exit 1
        }
        $deps | Out-File -FilePath $depFile -Encoding utf8
        Remove-Item $extractPy -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  [~] 依赖清单：$depFile（$((Get-Content $depFile | Measure-Object -Line).Lines) 项）" -ForegroundColor Cyan
    if (-not (Test-Path "$env:TEMP\hermes-venv\Scripts\pip.exe")) {
        Write-Host "  [~] venv 内补装 pip（走清华 PyPI）..." -ForegroundColor Cyan
        Invoke-NativeChecked { & "$uvDir\uv.exe" pip install pip } | Out-Null
    }
    # 先试清华 PyPI 镜像（直连）
    $pipRc = Invoke-NativeChecked { & $pyExe -m pip download -r $depFile -d $wheelsDir --index-url $env:PIP_INDEX_URL }
    $wheelCountAfter = @(Get-ChildItem $wheelsDir -Filter "*.whl" -ErrorAction SilentlyContinue).Count
    if ($pipRc -ne 0 -or $wheelCountAfter -eq 0) {
        # 回退阿里云 PyPI
        Write-Host "  [!] 清华 PyPI 失败（exit=$pipRc），回退阿里云 PyPI..." -ForegroundColor Yellow
        $pipRc = Invoke-NativeChecked { & $pyExe -m pip download -r $depFile -d $wheelsDir --index-url "https://mirrors.aliyun.com/pypi/simple/" }
        $wheelCountAfter = @(Get-ChildItem $wheelsDir -Filter "*.whl" -ErrorAction SilentlyContinue).Count
    }
    if ($pipRc -ne 0 -or $wheelCountAfter -eq 0) {
        Write-Host "  [X] 从国内 PyPI 下载 Python 依赖失败（exit=$pipRc），详情：" -ForegroundColor Red
        $prevEap2 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $pyExe -m pip download -r $depFile -d $wheelsDir --index-url $env:PIP_INDEX_URL 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        $ErrorActionPreference = $prevEap2
        Pop-Location
        exit 1
    }
} else {
    Write-Host "  [!] uv 未下载，跳过 Python 依赖" -ForegroundColor Yellow
}
Pop-Location
}
$wheelCount = (Get-ChildItem $wheelsDir -Filter "*.whl" | Measure-Object).Count
Write-Host "  [OK] $wheelCount wheels" -ForegroundColor Green

# ============================================================================
# 6b. 打包 Python 3.11 运行时（离线机器无法联网下载解释器）
# 策略：python.tar 是**缓存产物**，只服务于"进包"这一步——离线端不需要它。
#   已有合法 python.tar → 直接进包，绝不再下载/解包。
#   没有（首次构建/校验不过）→ 用本机 uv 的 Python 3.11 现打一个。
#   本机也没有 → 才自动下载（npmmirror 镜像）。
# 注意：python-build-standalone 的目录名就是 -none 结尾（cpython-3.11.15-...-none
# 是正常名字！），校验只看"版本号完整"（cpython-3.11.\d+），不要误判 -none。
# ============================================================================
Write-Host "-> 打包 Python 3.11 运行时..." -ForegroundColor Cyan
$pyTar = "$BuildDir\python.tar"
$pyTarValid = $false
if (Test-Path $pyTar) {
    # 校验缓存 tar 顶层目录名：必须带完整版本号 cpython-3.11.\d+（-none 结尾正常）
    $topDir = & $tarExe -tf $pyTar 2>$null | Select-Object -First 1
    if ($topDir -match '^cpython-3\.11\.\d+') {
        $pyTarValid = $true
        Write-Host "  [OK] 已有 python.tar（顶层 $topDir），跳过" -ForegroundColor Green
    } else {
        Write-Host "  [!] 缓存 python.tar 顶层 '$topDir' 无完整版本号，删除重新打包" -ForegroundColor Yellow
        Remove-Item $pyTar -Force
    }
}
if (-not $pyTarValid) {
# ============================================================
# 定位本机 uv managed Python 3.11（uv python dir 拿绝对根，避免假设路径）
# ============================================================
Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
$env:Path = $env:Path -replace [regex]::Escape("$env:TEMP\hermes-venv\Scripts;"), ""

function Get-UvPythonDir {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $dir = & "$uvDir\uv.exe" python dir 2>$null | Select-Object -First 1
    $ErrorActionPreference = $prev
    if ($dir -and (Test-Path $dir)) { return ([string]$dir).TrimEnd('\') }
    return $null
}
function Find-ManagedPython311 {
    $root = Get-UvPythonDir
    if (-not $root) { return $null }
    # 注意坑：uv 会把 "cpython-3.11-windows-x86_64-none"（无版本号）建成指向
    # "cpython-3.11.15-windows-x86_64-none" 的符号链接别名（3.11=大版本，3.11.15=物理版）。
    # 必须打物理目录（带版本号），绝不能打符号链接（tar 跟随链接会打出别名目录名，uv 不认）！
    $cands = @(Get-ChildItem $root -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^cpython-3\.11\.\d+' })
    if ($cands.Count -eq 0) {
        # 极端情况：只有别名（无物理目录），跟随后退选它
        $cands = @(Get-ChildItem $root -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue)
    }
    if ($cands.Count -eq 0) { return $null }
    $chosen = $cands | Sort-Object Name -Descending | Select-Object -First 1
    return ([string]$chosen.FullName).TrimEnd('\')
}

$pyRuntimePath = Find-ManagedPython311
if (-not $pyRuntimePath) {
    Write-Host "  [~] 本机没有 Python 3.11，自动下载（npmmirror 镜像）..." -ForegroundColor Cyan
    $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & "$uvDir\uv.exe" python install 3.11 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    $installRc = $LASTEXITCODE
    if ($installRc -ne 0) {
        Write-Host "  [!] npmmirror 解释器镜像失败，回退 GitHub 代理..." -ForegroundColor Yellow
        $env:UV_PYTHON_INSTALL_MIRROR = "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"
        & "$uvDir\uv.exe" python install 3.11 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        $installRc = $LASTEXITCODE
    }
    $ErrorActionPreference = $prev
    if ($installRc -ne 0) {
        Write-Host "  [X] Python 3.11 下载失败（exit=$installRc），离线包无法构建" -ForegroundColor Red
        exit 1
    }
    $pyRuntimePath = Find-ManagedPython311
}
if (-not $pyRuntimePath -or -not (Test-Path "$pyRuntimePath\python.exe")) {
    Write-Host "  [X] 仍找不到 Python 3.11 解释器目录" -ForegroundColor Red
    $root = Get-UvPythonDir
    Write-Host "      uv python dir: $root" -ForegroundColor Red
    if ($root) {
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      - $($_.Name)" -ForegroundColor Red }
    }
    exit 1
}
# 打包成单个 python.tar（无压缩，秒级；顶层目录为 cpython-3.11.x/）
# 必须用 Windows 自带 tar.exe（Git Bash 的 tar 会把 "C:" 当远程主机）
# 用 Push-Location 代替 -C 参数（更稳，不依赖 tar 的路径解析）
$pyParent = [System.IO.Path]::GetDirectoryName($pyRuntimePath)
$pyLeaf = [System.IO.Path]::GetFileName($pyRuntimePath)
Write-Host "  [~] Python 运行时: $pyRuntimePath" -ForegroundColor Cyan
Remove-Item $pyTar -Force -ErrorAction SilentlyContinue
Push-Location $pyParent
& $tarExe -cf $pyTar $pyLeaf
$tarRc = $LASTEXITCODE
Pop-Location
if ($tarRc -ne 0 -or -not (Test-Path $pyTar)) {
    Write-Host "  [X] python.tar 打包失败（rc=$tarRc，parent=$pyParent，leaf=$pyLeaf）" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Python 运行时已打包 python.tar" -ForegroundColor Green
}

# ============================================================================
# 7. 下载 npm 缓存
# 策略：npm install 生成缓存后打包成单个 npm-cache.tar（无压缩），
# 进包/分发只带 tar，离线安装时再解压。避免几万碎文件进包拖慢打包。
# ============================================================================
Write-Host "-> [7/8] 下载 npm 依赖..." -ForegroundColor Cyan
$npmCacheDir = "$BuildDir\npm-cache"
$npmTar = "$BuildDir\npm-cache.tar"
if (Test-Path $npmTar) {
    Write-Host "  [OK] 已有 npm-cache.tar，跳过下载" -ForegroundColor Green
} else {
New-Item -ItemType Directory -Force -Path $npmCacheDir | Out-Null
Push-Location $hermesSrc
# 清掉上次失败遗留的 node_modules 半成品
Remove-Item "$hermesSrc\node_modules" -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path "$nodeDir\node.exe") {
    $env:Path = "$nodeDir;${env:Path}"
    $nodeVer = & "$nodeDir\node.exe" --version 2>$null
    Write-Host "  [~] Node $nodeVer ($(Split-Path $nodeDir -Leaf))" -ForegroundColor Cyan
}
# 用 node 直接跑 npm-cli.js，绕开 npm.cmd 的路径推断逻辑
# （避免 "Could not determine Node.js install directory"）
$npmCli = "$nodeDir\node_modules\npm\bin\npm-cli.js"
if (-not (Test-Path $npmCli)) {
    Write-Host "  [X] 未找到 npm-cli.js: $npmCli（Node 解压不完整？）" -ForegroundColor Red
    Pop-Location
    exit 1
}
$npmRc = Invoke-NativeChecked { & "$nodeDir\node.exe" $npmCli install --prefer-offline --cache $npmCacheDir }
if ($npmRc -ne 0) {
    $npmRc = Invoke-NativeChecked { & "$nodeDir\node.exe" $npmCli install --cache $npmCacheDir }
}
if ($npmRc -ne 0) {
    Write-Host "  [X] npm 依赖安装失败（exit=$npmRc），详情：" -ForegroundColor Red
    $prevEap6 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & "$nodeDir\node.exe" $npmCli install --cache $npmCacheDir 2>&1 |
        ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    $ErrorActionPreference = $prevEap6
    Pop-Location
    exit 1
}
Pop-Location
# 打包 npm 缓存成单个 tar（无压缩；cacache 内容多为已压缩数据，tar 即可）
Remove-Item $npmTar -Force -ErrorAction SilentlyContinue
& $tarExe -cf $npmTar -C $BuildDir npm-cache
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $npmTar)) {
    Write-Host "  [X] npm-cache.tar 打包失败" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] npm cache（已打包 npm-cache.tar）" -ForegroundColor Green
}

# ============================================================================
# 8. 打包
# ============================================================================
Write-Host "-> [8/8] 打包离线安装包..." -ForegroundColor Cyan

# 构建目录结构（先清空旧 PkgDir，否则旧版残留的 python\、git\、node\ 目录
# 会和新复制的 python.tar 等并存，zip 里出现重复内容！）
$PkgDir = "$BuildDir\hermes-install-cn-v${hermesVersion}"
if (Test-Path $PkgDir) { Remove-Item $PkgDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null

# 复制组件（全部为单文件 zip/tar + 少量目录，避免几万碎文件拖慢压缩）
Copy-Item "$BuildDir\bin" "$PkgDir\" -Recurse -Force
if (Test-Path $gitTar) { Copy-Item $gitTar "$PkgDir\" -Force }
if (Test-Path $nodeZip) { Copy-Item $nodeZip "$PkgDir\" -Force }
if (Test-Path $pyTar) { Copy-Item $pyTar "$PkgDir\" -Force }
if (Test-Path $npmTar) { Copy-Item $npmTar "$PkgDir\" -Force }
if (Test-Path $ffmpegDir) { Copy-Item $ffmpegDir "$PkgDir\" -Recurse -Force }
if (Test-Path $rgDir) { Copy-Item $rgDir "$PkgDir\" -Recurse -Force }

# Hermes 源码打成单个 hermes-agent.tar。
# 保留 .git（完整 git 仓库）！离线端把 origin 改成本地路径后，官方安装脚本
# 检测到有效仓库直接走本地 update，跳过 GitHub clone（最慢最不可靠的环节）。
# 仅排除 node_modules（由离线端 npm install --offline 从 npm-cache 恢复）。
# 打包前确保源码 checkout 到锁定版本、本地 main 分支指向当前 commit
#（官方脚本 update 分支默认 fetch origin main + checkout main）。
$hermesPkgSrc = "$env:TEMP\hermes-agent-pkg"
$hermesTar = "$BuildDir\hermes-agent.tar"
if (Test-Path $hermesPkgSrc) { Remove-Item $hermesPkgSrc -Recurse -Force }
Push-Location $hermesSrc
# 已 checkout 到锁定 tag（[5/8] 段）；本地若无 main 分支则创建指向当前 commit
$curBranch = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
if ($curBranch -eq "HEAD") {
    # detached HEAD（tag 检出）：建本地 main 分支指向当前 commit
    git branch -f main HEAD 2>$null | Out-Null
    git checkout -q main 2>$null | Out-Null
}
# 工作区必须干净（官方脚本 update 前会 stash，但干净最稳）
git reset -q --hard HEAD 2>$null | Out-Null
git clean -qfd 2>$null | Out-Null
Pop-Location
robocopy $hermesSrc $hermesPkgSrc /E /XD node_modules /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
if (-not (Test-Path "$hermesPkgSrc\pyproject.toml")) {
    Write-Host "  [X] 源码打包失败（robocopy 无输出）" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$hermesPkgSrc\.git")) {
    Write-Host "  [X] 源码打包失败（缺少 .git，官方脚本会重新 clone）" -ForegroundColor Red
    exit 1
}
Remove-Item $hermesTar -Force -ErrorAction SilentlyContinue
& $tarExe -cf $hermesTar -C $env:TEMP hermes-agent-pkg
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $hermesTar)) {
    Write-Host "  [X] hermes-agent.tar 打包失败" -ForegroundColor Red
    exit 1
}
Copy-Item $hermesTar "$PkgDir\" -Force

# 复制依赖缓存（wheels 为少量 whl，直接进包）
Copy-Item $wheelsDir "$PkgDir\" -Recurse -Force

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
# Windows 自带 tar.exe（Git Bash 的 /usr/bin/tar 会把 "C:" 当远程主机）
$tarExe = "$env:SystemRoot\System32\tar.exe"

Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|   Hermes Agent 离线安装                                |" -ForegroundColor Magenta
Write-Host "+-------------------------------------------------------+" -ForegroundColor Magenta

# 0. 校验离线包完整性（SHA256，防传输损坏/篡改）
Write-Host "-> 校验离线包完整性（SHA256）..." -ForegroundColor Cyan
if (Test-Path "$OfflineDir\SHA256SUMS.txt") {
    $checksumFailed = @()
    Get-Content "$OfflineDir\SHA256SUMS.txt" | ForEach-Object {
        if ($_ -match '^([0-9A-Fa-f]{64})\s+(.+)$') {
            $expectedHash = $Matches[1].ToUpper()
            $checksumRel = $Matches[2]
            $checksumAbs = Join-Path $OfflineDir $checksumRel
            if (Test-Path $checksumAbs) {
                $actualHash = (Get-FileHash -Algorithm SHA256 -Path $checksumAbs).Hash
                if ($actualHash -ne $expectedHash) { $checksumFailed += $checksumRel }
            } else { $checksumFailed += $checksumRel }
        }
    }
    if ($checksumFailed.Count -gt 0) {
        Write-Host "  [X] 以下文件校验失败，离线包可能损坏：$($checksumFailed -join ', ')" -ForegroundColor Red
        Write-Host "  [X] 请重新下载或比对 packages\*.sha256" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] 完整性校验通过" -ForegroundColor Green
} else {
    Write-Host "  [!] 未找到 SHA256SUMS.txt，跳过完整性校验" -ForegroundColor Yellow
}

# 1. uv
$uvDir = "$OfflineDir\bin"
Copy-Item "$uvDir\uv.exe" "$hermesBin\uv.exe" -Force
Write-Host "  [OK] uv" -ForegroundColor Green

# 2. Git（git.tar → tar -xf 解压部署）
$gitTarget = "$hermesHome\git"
if (Test-Path "$OfflineDir\git.tar") {
    if (-not (Test-Path "$gitTarget\cmd\git.exe")) {
        Remove-Item $gitTarget -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $gitTarget | Out-Null
        & $tarExe -xf "$OfflineDir\git.tar" -C $gitTarget
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [X] git.tar 解压失败" -ForegroundColor Red
            exit 1
        }
    }
} else {
    Write-Host "  [X] 离线包缺少 git.tar" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$gitTarget\cmd\git.exe")) {
    Write-Host "  [X] 解压后缺少 git\cmd\git.exe" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$gitTarget\bin\bash.exe")) {
    Write-Host "  [X] 解压后缺少 git\bin\bash.exe" -ForegroundColor Red
    exit 1
}
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

# 3. Node.js（node.zip → 解压，顶层目录处理成 $hermesHome\node）
if (Test-Path "$OfflineDir\node.zip") {
    if (-not (Test-Path "$hermesHome\node\node.exe")) {
        $nodeExtract = "$env:TEMP\hermes-node-extract"
        Remove-Item $nodeExtract -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive "$OfflineDir\node.zip" $nodeExtract -Force
        $nodeSrc = Get-ChildItem $nodeExtract -Directory | Select-Object -First 1
        if (-not $nodeSrc -or -not (Test-Path "$($nodeSrc.FullName)\node.exe")) {
            Write-Host "  [X] node.zip 结构无效" -ForegroundColor Red
            exit 1
        }
        Remove-Item "$hermesHome\node" -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item $nodeSrc.FullName "$hermesHome\node"
        Remove-Item $nodeExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:Path = "$hermesHome\node;${env:Path}"
    Write-Host "  [OK] Node.js" -ForegroundColor Green
}

# 3b. ripgrep
if (Test-Path "$OfflineDir\rg\rg.exe") {
    New-Item "$hermesBin\rg" -ItemType Directory -Force | Out-Null
    Copy-Item "$OfflineDir\rg\rg.exe" "$hermesBin\rg\rg.exe" -Force
    $env:Path = "$hermesBin\rg;${env:Path}"
    Write-Host "  [OK] ripgrep" -ForegroundColor Green
}

# 3c. Python 3.11 运行时（python.tar → 解压到 uv Python 安装目录，uv 自动发现）
if (Test-Path "$OfflineDir\python.tar") {
    # 先问 uv 真正的托管 Python 根目录（Local/Roaming 因机器而异，别写死 %LOCALAPPDATA%）
    $uvRealRoot = & "$hermesBin\uv.exe" python dir 2>$null | Select-Object -First 1
    $uvPythonDir = if ($uvRealRoot -and (Test-Path $uvRealRoot)) { ([string]$uvRealRoot).TrimEnd('\') }
                   elseif ($env:UV_PYTHON_INSTALL_DIR) { $env:UV_PYTHON_INSTALL_DIR }
                   else { "$env:LOCALAPPDATA\uv\python" }
    New-Item -ItemType Directory -Force -Path $uvPythonDir | Out-Null
    # 清掉旧版本/错误残留（避免之前装错的内容和多版本堆积）
    Get-ChildItem $uvPythonDir -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    Remove-Item "$uvPythonDir\Scripts" -Recurse -Force -ErrorAction SilentlyContinue
    & $tarExe -xf "$OfflineDir\python.tar" -C $uvPythonDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] python.tar 解压失败" -ForegroundColor Red
        exit 1
    }
    $deployedPy = Get-ChildItem $uvPythonDir -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^cpython-3\.11\.\d+' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $deployedPy) {
        # 兜底：无版本号别名（uv 建的 symlink）也算装上了
        $deployedPy = Get-ChildItem $uvPythonDir -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    }
    if ($deployedPy) {
        Write-Host "  [OK] Python 3.11 运行时 → $uvPythonDir\$($deployedPy.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [!] python.tar 解压后未找到 cpython-3.11* 目录，请检查" -ForegroundColor Yellow
    }
}

# 4. ffmpeg
if (Test-Path "$OfflineDir\ffmpeg\ffmpeg.exe") {
    $env:Path = "$OfflineDir\ffmpeg;${env:Path}"
    Write-Host "  [OK] ffmpeg" -ForegroundColor Green
}

# 5. Hermes 源码（hermes-agent.tar → 解压并重命名）
Write-Host "-> 部署 Hermes 源码..." -ForegroundColor Cyan
if (-not (Test-Path "$OfflineDir\hermes-agent.tar")) {
    Write-Host "  [X] 离线包缺少 hermes-agent.tar" -ForegroundColor Red
    exit 1
}
& $tarExe -xf "$OfflineDir\hermes-agent.tar" -C $hermesHome
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] hermes-agent.tar 解压失败" -ForegroundColor Red
    exit 1
}
if (Test-Path "$hermesHome\hermes-agent-pkg") {
    Remove-Item "$hermesHome\hermes-agent" -Recurse -Force -ErrorAction SilentlyContinue
    Rename-Item "$hermesHome\hermes-agent-pkg" "hermes-agent"
}
if (-not (Test-Path "$hermesHome\hermes-agent\pyproject.toml")) {
    Write-Host "  [X] 源码部署失败（未找到 pyproject.toml）" -ForegroundColor Red
    exit 1
}
# 5b. 源码 git origin 改为本地自引用：官方安装脚本 update 时 fetch/pull 走本地，
#     秒过且不碰 GitHub（省掉 clone/fetch 这个最慢最不可靠的环节）。
#     打包时已保证本地 main 分支 = 锁定版本 commit。
$gitExe = "$gitTarget\cmd\git.exe"
& $gitExe -C "$hermesHome\hermes-agent" remote set-url origin "$hermesHome\hermes-agent" 2>$null
& $gitExe -C "$hermesHome\hermes-agent" branch --set-upstream-to=origin/main main 2>$null
Write-Host "  [OK] 源码已就位（git origin → 本地，官方脚本不再访问 GitHub）" -ForegroundColor Green

# 6. 离线缓存环境变量（官方脚本联网装依赖时，本地 wheels / npm-cache 优先）
if (Test-Path "$OfflineDir\wheels") { $env:UV_FIND_LINKS = "$OfflineDir\wheels" }
if (Test-Path "$OfflineDir\npm-cache") {
    $env:npm_config_cache = "$OfflineDir\npm-cache"
    $env:npm_config_prefer_offline = "true"
}

# 7. 调用 Hermes 官方安装脚本完成本体安装（venv / 依赖 / hermes 命令 / PATH / 配置）
#    官方脚本检测到基础软件已就绪后跳过 prereqs，只跑 install + finalize 段。
Write-Host "-> 调用 Hermes 官方安装脚本（venv/依赖/hermes 命令）..." -ForegroundColor Cyan
$officialInstall = "$hermesHome\hermes-agent\scripts\install.ps1"
if (-not (Test-Path $officialInstall)) {
    Write-Host "  [X] 未找到官方安装脚本: $officialInstall" -ForegroundColor Red
    exit 1
}
& $officialInstall -NonInteractive
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [X] Hermes 官方安装脚本执行失败（exit=$LASTEXITCODE）" -ForegroundColor Red
    exit 1
}

Write-Host "`n[OK] 安装完成！重启终端后输入 hermes 即可使用。" -ForegroundColor Green
Write-Host "     （模型 API / 平台网关等仍需联网，依赖走国内镜像加速）" -ForegroundColor DarkGray
'@

$offlineScript | Out-File -FilePath "$PkgDir\install-offline.ps1" -Encoding utf8

# ============================================================================
# 生成包内关键文件 SHA256 校验清单（离线安装时逐项验证，防传输损坏）
# 全部为单文件组件（zip/tar/exe），并行计算快；不再遍历碎文件目录
# ============================================================================
$checksumFiles = @(
    "bin\uv.exe",
    "git.tar",
    "node.zip",
    "python.tar",
    "npm-cache.tar",
    "hermes-agent.tar"
)
if (Test-Path "$PkgDir\rg\rg.exe") { $checksumFiles += "rg\rg.exe" }
if (Test-Path "$PkgDir\ffmpeg\ffmpeg.exe") { $checksumFiles += "ffmpeg\ffmpeg.exe" }

# 并行 SHA256（PS 5.1 兼容）。
# 坑1：Task.Run 后台线程无 PowerShell Runspace，scriptblock 无法执行；
# 坑2：Start-ThreadJob 老 PS 5.1 没这个模块。
# 正解：RunspacePool（内核 API，PS 5.1 必有），每文件一个管道并行哈希。
$absFiles = @($checksumFiles | ForEach-Object { Join-Path $PkgDir $_ } | Where-Object { Test-Path $_ })
try {
    $pool = [runspacefactory]::CreateRunspacePool(1, [Environment]::ProcessorCount)
    $pool.Open()
    $jobs = foreach ($fileAbs in $absFiles) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript({
            param($p)
            $stream = [System.IO.File]::OpenRead($p)
            try {
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                try { $b = $sha256.ComputeHash($stream) }
                finally { $sha256.Dispose() }
                [BitConverter]::ToString($b).Replace('-', '')
            } finally { $stream.Dispose() }
        }).AddArgument($fileAbs)
        [pscustomobject]@{ Ps = $ps; Async = $ps.BeginInvoke(); Path = $fileAbs }
    }
    $hashByRel = @{}
    foreach ($j in $jobs) {
        $hash = $j.Ps.EndInvoke($j.Async)[0]
        $rel = $j.Path.Substring($PkgDir.Length + 1)
        $hashByRel[$rel] = $hash
        $j.Ps.Dispose()
    }
    $pool.Dispose()
    $checksumLines = foreach ($rel in $checksumFiles) {
        if ($hashByRel.ContainsKey($rel)) { "$($hashByRel[$rel])  $rel" }
    }
} catch {
    # 并行失败不阻断构建：回退串行 Get-FileHash
    Write-Host "  [!] 并行哈希失败，回退串行：$($_.Exception.Message)" -ForegroundColor Yellow
    $checksumLines = foreach ($rel in $checksumFiles) {
        $abs = Join-Path $PkgDir $rel
        if (Test-Path $abs) {
            "$((Get-FileHash -Algorithm SHA256 -Path $abs).Hash)  $rel"
        }
    }
}
$checksumLines | Out-File -FilePath "$PkgDir\SHA256SUMS.txt" -Encoding ascii
Write-Host "  [OK] SHA256SUMS.txt（$($checksumLines.Count) 项，并行计算）" -ForegroundColor Green

# 压缩（用 .NET ZipFile 替代 Compress-Archive：PS 5.1 的 Compress-Archive
# 单线程且逐文件 IO，大包慢 3-5 倍）
$packageFile = "$OutputDir\hermes-install-cn-v${hermesVersion}.zip"
if (Test-Path $packageFile) { Remove-Item $packageFile -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($PkgDir, $packageFile,
    [System.IO.Compression.CompressionLevel]::Optimal, $false)

# 打包后生成 zip 自身的 SHA256（下载后验证整包）
$zipHash = (Get-FileHash -Algorithm SHA256 -Path $packageFile).Hash
"$zipHash  $([System.IO.Path]::GetFileName($packageFile))" |
    Out-File -FilePath "$packageFile.sha256" -Encoding ascii

# 保留构建缓存（增量构建复用），不删除 BuildDir
$pkgSize = "{0:N1}" -f ((Get-Item $packageFile).Length / 1MB)
Write-Host "`n[OK] 离线包已生成: $packageFile ($pkgSize MB)" -ForegroundColor Green
Write-Host "      SHA256: $packageFile.sha256" -ForegroundColor Green
Write-Host "Hermes 版本: $hermesVersion" -ForegroundColor Cyan
Write-Host "构建缓存保留在: $BuildDir （下次构建自动复用，-Force 可全量重建）" -ForegroundColor DarkGray
Write-Host "上传到 Gitee Releases 或百度网盘即可分发。" -ForegroundColor Yellow
