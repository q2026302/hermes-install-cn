# Hermes 国内安装工具 · hermes-install-cn

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

国内网络环境下一键安装 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（Nous Research 开源 AI 助手）。

> 本项目不是 Hermes 中国版，而是**安装辅助工具 + 教程**。
> Hermes 本身是 MIT 协议的开源项目，本仓库只提供适配国内网络的安装脚本和离线安装包。

---

## ✨ 功能

| 方式 | 说明 | 适用场景 |
|------|------|----------|
| **在线安装** | 一行命令，依赖从国内镜像+代理链加速下载 | 有网但 GitHub 直连慢 |
| **离线安装** | 下载离线包 → 解压 → 运行，全程 0 网络 | 内网/无网络/网络极差 |

---

## 🚀 在线安装

```powershell
irm https://gitee.com/q2026302/hermes-install-cn/raw/main/install.ps1 | iex
```

或下载 `install.ps1` 后本地运行：

```powershell
.\install.ps1
```

安装过程 5-15 分钟，完成后重启终端，输入 `hermes` 即可使用。

### 镜像加速策略

| 组件 | 来源 | 说明 |
|------|------|------|
| npm 包 | `registry.npmmirror.com` | 淘宝 npm 镜像，直连 |
| Node.js | `npmmirror.com/mirrors/node/` | 淘宝 Node 镜像，直连 |
| Electron | `npmmirror.com/mirrors/electron/` | 淘宝 Electron 镜像，直连 |
| Playwright | `npmmirror.com/mirrors/playwright/` | 淘宝 Playwright 镜像，直连 |
| PyPI | `mirrors.tuna.tsinghua.edu.cn` | 清华 PyPI 镜像，直连 |
| Git / ffmpeg | `winget` 安装 | winget CDN 国内直连 |
| uv / Hermes 源码 | 代理链 `ghfast.top` → `ghproxy.com` | 多代理自动回退 |
| Python 运行时 | uv 通过代理链下载 | 同上 |

---

## 📦 离线安装

适合无网络环境或反复安装的场景。

下载离线包 → 解压 → 运行 `install-offline.ps1`，全程不需要联网。

离线包下载（百度网盘）：*待上传*

---

## 📁 项目结构

```
hermes-install-cn/
├── install.ps1              # 在线安装脚本
├── install-offline.ps1      # 离线安装脚本（包内使用）
├── build-package.ps1        # 打包脚本
├── packages/                # 离线包输出目录
├── LICENSE
└── README.md
```

---

## 🔖 版本

离线包文件名格式：`hermes-install-cn-v{hermes版本号}.zip`

---

## 📜 许可证

[MIT](LICENSE) · Based on [Hermes Agent](https://github.com/NousResearch/hermes-agent) (MIT) by Nous Research
