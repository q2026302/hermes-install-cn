# Hermes 国内安装工具 · hermes-install-cn

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

国内网络环境下一键安装 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（Nous Research 开源 AI 助手）。

> 本项目不是 Hermes 中国版，而是**安装辅助工具 + 教程**。
> Hermes 本身是 MIT 协议的开源项目，本仓库只提供适配国内网络的安装脚本和离线安装包。

---

## ✨ 功能

| 方式 | 说明 | 适用场景 |
|------|------|----------|
| **在线安装** | 一行命令，所有依赖从国内镜像加速下载 | 有网但 GitHub 直连慢 |
| **离线安装** | 下载离线包 → 解压 → 运行，全程 0 网络 | 内网/无网络/网络极差 |

---

## 🚀 在线安装

### 方法一：直接运行（推荐）

```powershell
irm https://gitee.com/你的用户名/hermes-install-cn/raw/main/install.ps1 | iex
```

### 方法二：下载后运行

```powershell
# 保存 install.ps1 到本地，右键 → 用 PowerShell 运行
.\install.ps1
```

### 方法三：有代理客户端

```powershell
.\install.ps1 -Proxy "http://127.0.0.1:7890"
```

> 安装过程 5-15 分钟，取决于网络和机器性能。
> 安装完成后重启终端，输入 `hermes` 即可使用。

---

## 📦 离线安装

适合无网络环境或反复安装的场景。

### 下载离线包

| 渠道 | 链接 |
|------|------|
| Gitee Releases | [releases](https://gitee.com/你的用户名/hermes-install-cn/releases) |
| 百度网盘 | 待上传（见下方提取码） |

### 使用

```powershell
# 1. 下载 hermes-install-cn-v{hermes版本号}.zip
# 2. 解压到任意目录
# 3. 进入目录，运行：

.\install-offline.ps1
```

---

## 📁 项目结构

```
hermes-install-cn/
├── install.ps1              # 在线安装（镜像加速）
├── install-offline.ps1      # 离线安装（包内使用）
├── build-package.ps1        # 打包脚本（生成离线安装包）
├── packages/                # 离线包输出目录
│   └── hermes-install-cn-v*.zip
├── LICENSE                  # MIT
└── README.md
```

---

## 🔖 版本说明

离线包的版本号与对应的 Hermes 版本一致：

| 离线包 | 内含 Hermes 版本 | 说明 |
|--------|------------------|------|
| `hermes-install-cn-v2.3.0.zip` | Hermes v2.3.0 | 最新版 |
| `hermes-install-cn-v0.19.0.zip` | Hermes v0.19.0 | 旧版 |

安装脚本（install.ps1）始终从镜像拉取**最新版** Hermes。
如需固定版本，请使用对应版本的离线包。

---

## 🧰 构建离线包

```powershell
# 在一台能联网的机器上运行
.\build-package.ps1
```

会自动下载：
- uv 包管理器
- Python 3.11
- Git
- Node.js
- ffmpeg
- Hermes 源码
- 所有 Python 依赖（wheels）
- 所有 Node 依赖（npm cache）

输出到 `packages/hermes-install-cn-v{版本号}.zip`。

---

## 📜 许可证

[MIT](LICENSE)

Based on [Hermes Agent](https://github.com/NousResearch/hermes-agent) (MIT) by Nous Research.
