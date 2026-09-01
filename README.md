# DDNScg

一个面向 VPS 的轻量 Cloudflare DDNS 脚本，自动识别 IPv4、IPv6 或双栈网络，并按实际可用地址创建或更新 A / AAAA 记录。

## 主要特点

- 支持纯 IPv4、纯 IPv6和 IPv4/IPv6 双栈 VPS
- `auto` 模式自动决定更新 A、AAAA 或两者
- 安装文件从 `raw.githubusercontent.com` 获取，该域名原生支持 IPv6；纯 IPv6 VPS 不依赖 `github.com` 或 `api.github.com`
- IPv4 默认优先检测真实出口地址，兼容 NAT VPS
- IPv6 默认优先使用系统默认路由选中的源地址，适合动态 IPv6
- 支持一个地址同步到多个记录名
- 记录不存在时自动创建，内容未变化时不重复写入
- 使用 Cloudflare API Token，不支持风险更高的 Global API Key
- systemd 定时器每 5 分钟运行；无 systemd 时回退到 cron
- 配置文件权限为 `600`，systemd 服务包含基础沙箱限制

## 一键安装

> [!IMPORTANT]
> 在线安装要求仓库为公开仓库。私有仓库请先下载源码，再在源码目录运行 `sudo bash install.sh`。

VPS 通常直接使用 `root` 登录，可运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/DDNScg/main/install.sh)
```

纯 IPv6 VPS 可显式强制 IPv6：

```bash
bash <(curl -6fsSL https://raw.githubusercontent.com/xinian5216/DDNScg/main/install.sh)
```

普通用户使用 `sudo` 时，建议先保存安装器，以免 `sudo` 关闭进程替换所用的文件描述符：

```bash
curl -fsSL https://raw.githubusercontent.com/xinian5216/DDNScg/main/install.sh -o /tmp/ddnscg-install.sh
sudo bash /tmp/ddnscg-install.sh
```

安装器支持 Debian、Ubuntu、RHEL、Rocky Linux、AlmaLinux、Fedora、Alpine Linux 和 openSUSE 常见包管理器。

## Cloudflare Token 权限

在 Cloudflare 的 **API Tokens** 页面创建自定义 Token：

| 权限 | 用途 | 是否必需 |
| --- | --- | --- |
| Zone → DNS → Edit | 查询、创建和更新 DNS 记录 | 是 |
| Zone → Zone → Read | 根据根域名自动查询 Zone ID | 未填写 `CF_ZONE_ID` 时需要 |

资源范围建议只选择需要 DDNS 的那个 Zone，不要授权全部域名。

## 配置

一键安装会进入交互配置，也可以稍后运行：

```bash
sudo ddnscg configure
```

默认配置位于 `/etc/ddnscg/config`：

```ini
CF_API_TOKEN=your_token
CF_ZONE_ID=
CF_ZONE=example.com
RECORD_NAMES=vps.example.com
RECORD_TYPES=auto
IPV4_SOURCE=auto
IPV6_SOURCE=auto
INTERFACE=auto
PROXIED=false
TTL=1
```

多个记录共用相同地址时，用逗号分隔：

```ini
RECORD_NAMES=vps.example.com,ssh.example.com
```

### 网络栈行为

| VPS 网络 | `RECORD_TYPES=auto` 的结果 |
| --- | --- |
| 仅 IPv4 | 只创建或更新 A |
| 仅 IPv6 | 只创建或更新 AAAA |
| IPv4 + IPv6 | 同时创建或更新 A 与 AAAA |

地址来源有三种：

- `external`：通过 Cloudflare Trace 获取实际出口地址。
- `interface`：读取本机默认路由选中的源地址；指定 `INTERFACE=eth0` 后只从该网卡取地址。
- `auto`：IPv4 先尝试 `external`，适合 NAT；IPv6 先尝试 `interface`，避免不必要地依赖第三方 IP 查询。

如果 VPS 同时存在原生 IPv6、WARP 或多条默认路由，而你希望域名始终指向原生入站地址，请设置：

```ini
IPV6_SOURCE=interface
INTERFACE=eth0
```

### Cloudflare 代理

`PROXIED=false` 是更稳妥的默认值。SSH 或其他非 HTTP 的 TCP/UDP 服务，以及 Cloudflare 不支持代理的端口，都应保持关闭；只有明确需要 Cloudflare 橙云代理时才改为 `true`。

## 常用命令

```bash
# 预演：查询地址和 Cloudflare 当前记录，但不写入
sudo ddnscg run --dry-run

# 立即同步
sudo ddnscg run

# 查看脚本检测到的地址
sudo ddnscg ip

# 查看配置摘要、最近一次结果和定时器
sudo ddnscg status

# 查看 systemd 日志
journalctl -u ddnscg.service --since today --no-pager
```

## 更新与卸载

```bash
# 更新程序，保留配置
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/DDNScg/main/install.sh) --update

# 卸载，保留配置
sudo bash install.sh --uninstall

# 完全卸载，同时删除配置和运行记录
sudo bash install.sh --uninstall --purge
```

## 文件位置

| 路径 | 作用 |
| --- | --- |
| `/usr/local/bin/ddnscg` | 主程序 |
| `/etc/ddnscg/config` | 配置与 API Token |
| `/var/lib/ddnscg/last-run` | 最近一次成功运行结果 |
| `/etc/systemd/system/ddnscg.service` | systemd 单次任务 |
| `/etc/systemd/system/ddnscg.timer` | 5 分钟定时器 |

## 本地测试

测试使用模拟的 Cloudflare API，不会改动真实 DNS：

```bash
bash -n ddnscg.sh install.sh
bash tests/test.sh
```

## License

[MIT](LICENSE)
