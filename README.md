# TUU Toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 一键安装

root 权限下执行下面命令，会将脚本保存到当前目录并自动进入菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/phyrevue/tuu-toolkit/main/tuu-toolkit.sh -o tuu-toolkit.sh && chmod +x tuu-toolkit.sh && ./tuu-toolkit.sh
```

以后可在该目录直接执行 `./tuu-toolkit.sh` 再次进入工具箱。

TUU Toolkit 是一键管理代理服务的中文 Shell 脚本，支持安装、配置、管理以下三种代理：

| 服务 | 类型 | TCP | UDP |
| ---- | ---- | :-: | :-: |
| [GOST](https://github.com/go-gost/gost) (v3) | SOCKS5 | ✅ | ✅ |
| [Shadowsocks Rust](https://github.com/shadowsocks/shadowsocks-rust) | Shadowsocks | ✅ | ✅ |
| [Realm](https://github.com/zhboner/realm) | 端口转发 | ✅ | ✅ |

> **UDP 支持**：三种代理默认均开启 UDP（GOST 通过 SOCKS5 UDP-ASSOCIATE 中继、SS 为 `tcp_and_udp` 模式、Realm 为 `use_udp = true`），安装时会同时放行 TCP / UDP 防火墙端口。

## 功能特性

- **GOST SOCKS5**：带/不带用户名密码认证，自动安装最新版并创建 systemd / OpenRC 服务
- **Shadowsocks Rust**：默认 `aes-256-gcm`（不依赖时间同步，兼容性最好），可选 `2022-blake3` 系列；自动生成分享链接，更新时可保留原配置
- **Realm**：添加 / 删除 / 查看 TCP+UDP 端口转发规则，支持自定义监听地址与规则备注，可设置每日自动重启
- 自动检测发行版（Debian/Ubuntu、Alpine、CentOS/RHEL/Rocky/Alma）与系统服务管理器（systemd / OpenRC）
- 自动放行防火墙端口（支持 firewalld、ufw、iptables）；云服务商安全组需在控制台手动放行
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
tuu-toolkit.sh --diagnose # 生成排错报告
tuu-toolkit.sh --log      # 查看脚本错误日志
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
│ 4. 系统检测                  │
│ 5. 检测/更新脚本             │
│ 6. 安装基础依赖              │
│ 7. 日志与排错                │
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

## 日志与排错

遇到服务无法启动、转发不通等问题时，先在主菜单选择 `7) 日志与排错 -> 生成排错报告`，或执行 `./tuu-toolkit.sh --diagnose`。

- 报告开头是**问题摘要**，会自动检查：主程序能否运行（glibc / 架构不兼容）、配置和服务文件是否存在、服务是否运行或崩溃、端口是否监听或被占用、Realm 是否有规则及目标是否可达、OpenRC / systemd 状态、DNS 与 GitHub 连通性、磁盘空间等
- 后面附有系统信息、服务状态、配置内容、各服务错误日志、监听端口、防火墙规则和脚本日志
- 报告保存在 `/var/log/tuu-toolkit-diagnose/`，保留最近 10 份；**密码和 `ss://` 链接已脱敏**，但包含 IP 和端口，分享前请自行确认

脚本日志 `/var/log/tuu-toolkit.log` 会记录每次操作、所有警告和错误（含出错位置），以及失败命令（包管理器、下载、服务启停）的退出码和输出，超过 2MB 时自动截断。

| 日志 | 位置 |
| ---- | ---- |
| 脚本日志 | `/var/log/tuu-toolkit.log` |
| GOST | `/var/log/gost/gost.log`、`/var/log/gost/gost.err` |
| Shadowsocks Rust | `/var/log/ss-rust.log`、`/var/log/ss-rust.err` |
| Realm | `/var/log/realm.log`、`/var/log/realm.err` |

> systemd 系统上服务输出也可用 `journalctl -u <服务名>` 查看。

## 更新日志

- **2.0.6**
  - 新增「日志与排错」菜单与 `--diagnose` / `--log` 参数：一键生成带问题摘要的排错报告，脚本日志记录错误位置和失败命令输出
  - 修复 OpenRC 下服务进程退出后提示 `already been started` 而无法启动的问题；Realm 无转发规则时不再启动
  - 修复脚本更新检测读取过期 Release 版本的问题，改为以 main 分支脚本版本为准
  - Shadowsocks 默认加密改为 `aes-256-gcm`；选择 `2022-blake3` 加密时提示时间同步要求，并校验自定义密码格式
  - 安装/更新后检查服务是否真正运行，启动失败时直接显示日志，不再误报成功
  - 已有 SS 配置时可仅更新程序，保留端口、密码和分享链接
  - 系统禁用 IPv6 时 SS 自动改为监听 `0.0.0.0`
  - 2022 加密的分享链接改为 SIP002 规定的百分号编码格式，兼容严格按规范解析的客户端
  - OpenRC 服务文件句柄上限与 systemd 保持一致；wget 下载不再跳过证书校验；端口输入拒绝前导零
- **2.0.5**
  - Shadowsocks Rust 优先安装静态 musl 构建，兼容旧版 glibc；安装前自动验证二进制是否可运行
  - 一键运行命令会将 `tuu-toolkit.sh` 保存在当前目录，方便后续再次运行
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
