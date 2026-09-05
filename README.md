# TUU Toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 一键安装

root 权限下执行下面命令即可，无需下载文件，自动进入菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh)
```

TUU Toolkit 是一键管理代理服务的中文 Shell 脚本，支持安装、配置、管理以下三种代理：

| 服务 | 类型 | TCP | UDP |
| ---- | ---- | :-: | :-: |
| [GOST](https://github.com/go-gost/gost) (v3) | SOCKS5 | ✅ | ✅ |
| [Shadowsocks Rust](https://github.com/shadowsocks/shadowsocks-rust) | Shadowsocks | ✅ | ✅ |
| [Realm](https://github.com/zhboner/realm) | 端口转发 | ✅ | ✅ |

> **UDP 支持**：三种代理默认均开启 UDP（GOST 通过 SOCKS5 UDP-ASSOCIATE 中继、SS 为 `tcp_and_udp` 模式、Realm 为 `use_udp = true`），安装时会同时放行 TCP / UDP 防火墙端口。

## 功能特性

- **GOST SOCKS5**：带/不带用户名密码认证，自动安装最新版并创建 systemd / OpenRC 服务
- **Shadowsocks Rust**：支持 `2022-blake3` 等 AEAD 加密方法，自动生成分享链接
- **Realm**：添加 / 删除 / 查看 TCP+UDP 端口转发规则，支持自定义监听地址与规则备注，可设置每日自动重启
- 自动检测发行版（Debian/Ubuntu、Alpine、CentOS/RHEL/Rocky/Alma）与系统服务管理器（systemd / OpenRC）
- 自动放行防火墙端口（支持 firewalld、ufw、iptables、nftables 等）
- 自带脚本自检与在线更新功能

## 系统要求

- Linux 系统之一：
  - Debian / Ubuntu
  - Alpine
  - CentOS / RHEL / Rocky / Alma
- 需要 root 权限
- 架构支持 x86_64、aarch64 等常见平台（自动检测）

## 安装与使用

### 下载后本地运行

```bash
wget https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh -O tuu-toolkit.sh
chmod +x tuu-toolkit.sh
./tuu-toolkit.sh
```

### 命令行参数

```bash
tuu-toolkit.sh --check    # 检测系统信息
tuu-toolkit.sh --version  # 查看版本
tuu-toolkit.sh --update   # 在线更新脚本
tuu-toolkit.sh --help     # 帮助
```

## 菜单说明

```
┌──────────────────────────────┐
│         TUU Toolkit          │
├──────────────────────────────┤
│ 1. GOST SOCKS5               │
│ 2. Shadowsocks Rust          │
│ 3. Realm                     │
│ 4. 安装核心依赖              │
│ 5. 检测系统信息              │
│ 6. 检查更新                  │
│ 0. 退出                      │
└──────────────────────────────┘
```

进入各服务子菜单后可执行安装/更新、启停、重启、查看配置、卸载等操作。

## 配置文件位置

| 服务 | 配置文件 | 服务名 |
| ---- | -------- | ------ |
| GOST | `/etc/gost/config.yaml` | `gost` |
| Shadowsocks Rust | `/etc/ss-rust/config.json` | `ss-rust` |
| Realm | `/root/realm/config.toml` | `realm` |

> 修改脚本重新安装不会自动改写已存在的旧配置；若需让已安装服务生效，请在其子菜单中重新执行“安装/更新”，或手动修改上述配置文件后重启对应服务。

## 更新日志

- **2.0.4**
  - GOST SOCKS5 开启 UDP 中继支持（`handler.metadata.udp: true`），并自动放行 UDP 防火墙端口；现在三种代理均默认支持 TCP + UDP
- **2.0.3**
  - 其它修复与优化
- **2.0.0**
  - 重构为 GOST / Shadowsocks Rust / Realm 三合一管理脚本

## 免责声明

本脚本仅用于合法用途。使用者需遵守当地法律法规及目标服务器的服务条款。

## License

[MIT](LICENSE)
