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
| **离线安装** | 打包脚本生成离线包 → 解压 → 运行，全程 0 网络 | 内网/无网络/反复安装 |

---

## 🚀 在线安装

### 仓库地址（双镜像）

| 平台 | 地址 | 说明 |
|------|------|------|
| GitHub | `https://github.com/q2026302/hermes-install-cn` | 主仓库，实时更新 |
| Gitee | `https://gitee.com/q2026302/hermes-install-cn` | 国内镜像，自动同步，国内访问更快 |

### 一键安装（国内推荐 Gitee）

```powershell
# 方式一：Gitee 一行执行（国内直连，推荐）
irm https://gitee.com/q2026302/hermes-install-cn/raw/master/install.ps1 | iex

# 方式二：GitHub 一行执行（需能访问 GitHub）
irm https://raw.githubusercontent.com/q2026302/hermes-install-cn/master/install.ps1 | iex
```

或下载 `install.ps1` 后本地运行：

```powershell
# 允许执行脚本（当前进程临时放开）
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

安装过程 5-15 分钟，完成后**重启终端**，输入 `hermes` 即可使用。

### 安装器做了什么

在线安装器先准备好全部依赖，再原样调用 Hermes 官方安装脚本（不修改官方逻辑），官方脚本检测到依赖已就绪后直接复用：

| 组件 | 准备方式 | 说明 |
|------|----------|------|
| uv | GitHub 代理链下载 | 官方脚本复用 |
| Python 3.11 | `uv python install 3.11` | 官方脚本复用 |
| PortableGit + Git Bash | 清华镜像下载，自解压 | 完整版，含 bash/awk/sed，官方脚本复用 |
| Node.js 22 | npmmirror 镜像（index.json 解析真实版本） | 官方脚本复用 |
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

适合无网络环境或反复安装的场景。

### 1. 生成离线包（在一台能联网的 Windows 机器上）

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

### 2. 离线安装（目标机器）

解压离线包 → 运行包内 `install-offline.ps1`，全程不需要联网。

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

在线安装始终获取 Hermes 最新 main 分支；离线包文件名带 Hermes 版本号：`hermes-install-cn-v{hermes版本号}.zip`。

---

## 📜 许可证

[MIT](LICENSE) · Based on [Hermes Agent](https://github.com/NousResearch/hermes-agent) (MIT) by Nous Research
