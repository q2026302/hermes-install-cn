# Hermes 国内安装工具 · hermes-install-cn

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

国内网络环境下一键安装 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（Nous Research 开源 AI 助手）。

> 本项目不是 Hermes 中国版，而是**安装辅助工具 + 教程**。
> Hermes 本身是 MIT 协议的开源项目，本仓库只提供适配国内网络的安装脚本和离线安装包。

---

## ✨ 功能

| 方式 | 说明 | 适用场景 |
|------|------|----------|
| **在线安装** | 一键脚本，依赖全部走国内镜像 + GitHub 代理 | 有网但 GitHub 直连慢/失败 |
| **离线安装** | 下载离线包 → 解压 → 运行；基础软件本地秒装（0 网络），本体安装/使用仍需联网 | 基础软件下载慢/网络不稳定/反复安装 |

---

## 🚀 在线安装

### 仓库地址（双镜像）

| 平台 | 地址 | 说明 |
|------|------|------|
| GitHub | `https://github.com/q2026302/hermes-install-cn` | 主仓库，实时更新 |
| Gitee | `https://gitee.com/q2026302/hermes-install-cn` | 国内镜像，自动同步，国内访问更快 |

### 一键安装（国内推荐 Gitee）

> ⚠️ 注意：请使用下面的"下载到临时文件再执行"方式，**不要用 `irm | iex`**——脚本含中文，需带 BOM 编码才能在 Windows PowerShell 5.1 下正确显示/运行，而 `iex` 会被 BOM 干扰导致解析失败。

```powershell
# 方式一：Gitee（国内直连，推荐）
$p = "$env:TEMP\hermes-install-cn.ps1"
irm https://gitee.com/q2026302/hermes-install-cn/raw/master/install.ps1 -OutFile $p
& $p

# 方式二：GitHub（需能访问 GitHub）
$p = "$env:TEMP\hermes-install-cn.ps1"
irm https://raw.githubusercontent.com/q2026302/hermes-install-cn/master/install.ps1 -OutFile $p
& $p
```

或下载 `install.ps1` 后本地运行：

```powershell
# 允许执行脚本（当前进程临时放开）
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

安装过程 5-15 分钟，完成后**重启终端**。官方安装脚本结束时会**自动弹出配置向导**（填 API Key、选模型），也可以在重启后手动运行 `hermes setup` 配置，然后输入 `hermes` 即可使用。

> ⏱️ **耗时提醒**：在线安装需要联网下载全部依赖，其中 **uv、ffmpeg、Hermes 源码** 这几个组件走 GitHub 代理链（直连 → ghfast.top → gh-proxy.com），**即使有代理也比较慢**（ffmpeg 约 150MB、源码 clone 全历史），可能需要等待较长时间，属正常现象，请勿中断。
>
> 💡 如果网络条件差或需要反复安装，推荐直接使用下面的**离线安装包**（百度网盘下载，基础软件已打好包，安装时不再走 GitHub）。

### 安装器做了什么

在线安装器先准备好全部依赖，再原样调用 Hermes 官方安装脚本（不修改官方逻辑），官方脚本检测到依赖已就绪后直接复用：

| 组件 | 准备方式 | 说明 |
|------|----------|------|
| uv | GitHub 代理链下载 | 官方脚本复用 |
| Python 3.11 | `uv python install 3.11` | 官方脚本复用 |
| PortableGit + Git Bash | 清华镜像下载，自解压 | 完整版，含 bash/awk/sed，官方脚本复用 |
| Node.js 26 | npmmirror 镜像（index.json 解析真实版本） | 官方脚本复用 |
| Hermes 源码 | ghfast.top → gh-proxy.com HTTPS 预克隆 | 保留完整 Git 历史，官方脚本进入更新分支 |
| ripgrep / ffmpeg | GitHub 代理链预装 | 官方脚本检测到后跳过 winget |
| npm / PyPI / uv 索引 | 镜像环境变量（当前进程 + 用户级持久化） | 后续 `hermes update` 等继续生效 |

### 镜像与网络策略

| 资源 | 来源 |
|------|------|
| npm 包 / Node.js / Electron / Playwright | `npmmirror.com`（直连） |
| PyPI / uv 包索引 | `mirrors.tuna.tsinghua.edu.cn`（直连） |
| PortableGit | 清华 GitHub Release 镜像（直连） |
| GitHub Releases / 源码 clone | 直连优先 → `ghfast.top` → `gh-proxy.com` 回退 |

GitHub 代理仅作为直连失败后的兜底，不改变官方脚本的仓库结构。

---

## 📦 离线安装

适合**基础软件下载慢**（GitHub 代理慢）、网络不稳定或需要**反复安装**的场景。

离线包已打好全部基础软件（uv / PortableGit / Node.js / Python 3.11 / ripgrep / ffmpeg / Hermes 源码 / 依赖缓存），安装时基础软件 **0 网络、本地秒装**；Hermes 本体安装与**日常使用仍需联网**（模型 API、平台网关、`hermes update` 升级），联网部分自动走国内镜像加速。

### 1. 下载离线包（百度网盘）

| 内容 | 地址 |
|------|------|
| 共享目录（含各版本离线包） | https://pan.baidu.com/s/17T5j9yhp-dXbJObyt9uUWQ |
| 提取码 | `nsc6` |

目录内按版本存放离线包，命名格式：`hermes-install-cn-v{版本号}.zip`（如 `hermes-install-cn-v2026.7.30.zip`），**选择与你需要的 Hermes 版本对应的最新包下载**即可。

> 💡 如果目录内同时有多个版本，优先选最新构建的；版本号越大越新。

### 2. 安装（目标机器）

> ✅ 全程**不需要管理员权限**（安装到当前用户目录 `%LOCALAPPDATA%\hermes`），但**必须联网**（本体依赖安装和模型调用都需要）。

**第 1 步：解压** —— 将 zip 解压到任意目录（如 `D:\hermes-install-cn`），得到 `install-offline.ps1` 和若干组件文件。

**第 2 步：放开脚本执行权限** —— 打开 **PowerShell**，执行（只对当前窗口生效，安全）：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

**第 3 步：运行安装脚本**：

```powershell
cd D:\hermes-install-cn        # 换成你的解压目录
.\install-offline.ps1
```

安装过程会依次：校验包完整性 → 部署 uv/Git/Node/Python/ffmpeg（秒级）→ 部署源码 → 调用 Hermes 官方安装脚本完成本体安装（venv/依赖/hermes 命令/PATH，需联网）。看到 `[OK] 安装完成！` 即成功。

**第 4 步：重启终端**，让 PATH 生效。

**第 5 步：配置模型（重要）**：

```powershell
hermes setup
```

> ⚠️ **与在线版的差异**：在线版安装完成时**会自动弹出配置向导**（填 API Key / 选模型）；**离线版安装时不自动配置**（非交互模式，避免安装过程卡在提问上），装完后**必须手动运行 `hermes setup`** 完成 API Key 和模型配置才能开始使用。

### 3. 在线 vs 离线 行为对比

| 项目 | 在线安装 | 离线安装 |
|------|----------|----------|
| 基础软件来源 | 联网下载（uv/ffmpeg/源码走 GitHub 代理，慢） | 包内自带，本地秒装 |
| Hermes 源码 | 联网 clone（代理链，慢且偶发失败） | 包内自带，直接本地部署 |
| 本体依赖安装 | 联网（走国内镜像） | 联网（走国内镜像 + 包内 wheels 优先） |
| 装完是否自动配置模型 | ✅ 自动弹出配置向导 | ❌ 手动 `hermes setup` |
| 后续使用（模型/网关/升级） | 联网 | 联网 |

### 4. 生成离线包（可选，供构建/分发）

> 一般用户不需要这一步，直接用百度网盘的现成包即可。以下供**想自己打包/换版本**的联网 Windows 机器使用。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-package.ps1        # 增量构建：已有缓存自动复用
.\build-package.ps1 -Force # 强制全量重建
```

输出目录：`packages/`，文件名为 `hermes-install-cn-v{版本号}.zip`。

**版本锁定**：Hermes 各版本对依赖的要求不同（如 Node.js 门槛 22 → 26），脚本默认锁定 release tag `v2026.7.30`（与工具链版本匹配），不跟随 master。可用 `-HermesVersion` 指定其他 tag（或 `master`）：

```powershell
# 在线安装指定版本
irm https://gitee.com/q2026302/hermes-install-cn/raw/master/install.ps1 | iex  # 默认 v2026.7.30
.\install.ps1 -HermesVersion v2026.6.19

# 离线打包指定版本
.\build-package.ps1 -HermesVersion v2026.6.19
```

**增量构建**：已下载的组件缓存在 `cache\build\` 下（uv/Git/Node/源码/wheels 等），重复运行或网络中断后重跑会自动复用，只补缺失部分，避免全量重新下载。源码缓存命中时会自动切换到指定版本（不再跟随 master）。

**完整性校验**：打包会生成 `SHA256SUMS.txt`（包内关键组件校验，离线安装时自动逐项验证）和 `packages\*.zip.sha256`（整包校验，下载后人工验证）：

```powershell
# 下载后验证整包（可选，但推荐）
Get-FileHash hermes-install-cn-vX.zip
# 对比 packages\hermes-install-cn-vX.zip.sha256 中的哈希
```

打包内容：uv、完整 PortableGit（含 Git Bash）、Node.js、ripgrep、ffmpeg、**Python 3.11 运行时**、Hermes 源码、Python wheels（清华 PyPI）、npm cache。

---

## 📁 项目结构

```
hermes-install-cn/
├── install.ps1              # 在线安装脚本（预装依赖 → 原样执行官方脚本）
├── install-offline.ps1      # 离线安装脚本（打包时内嵌生成）
├── build-package.ps1        # 离线包构建脚本
├── packages/                # 离线包输出目录
├── LICENSE
└── README.md
```

---

## 🔖 版本

在线安装与离线包默认锁定 Hermes release tag `v2026.7.30`（与工具链版本匹配，可 `-HermesVersion` 指定其他 tag）；离线包文件名带 Hermes 版本号：`hermes-install-cn-v{hermes版本号}.zip`。

### 官方 Release 与本工具版本对应表

| 官方 Release tag | 官方 Hermes 版本 | 本工具离线包文件名 | 说明 |
|------|------|------|------|
| `v2026.7.30` | v0.19.1 | `hermes-install-cn-v2026.7.30.zip` | 当前默认锁定版本（Node ≥26，npm ≥12） |

> 官方发布：https://github.com/NousResearch/hermes-agent/releases 。后续官方出新版时，本表沿此格式向下追加。

---

## 📜 许可证

[MIT](LICENSE) · Based on [Hermes Agent](https://github.com/NousResearch/hermes-agent) (MIT) by Nous Research
