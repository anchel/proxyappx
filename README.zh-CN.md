[English](README.md) | 简体中文

# ProxyAppX — macOS 按应用代理

选中某个应用，让它的**全部网络流量**从指定的 SOCKS5 / HTTP 代理出去，其他应用不受影响。哪怕是不理会系统代理的应用（Electron、游戏、`curl` / `git` 等命令行工具）也一样有效。

完整需求见 [docs/PRD.md](docs/PRD.md)。

## 下载安装

1. 从 [Releases](https://github.com/anchel/proxyappx/releases) 下载最新的 `ProxyAppX-<版本>.zip`（已用 Developer ID 签名并经 Apple 公证）
2. 解压后把 `ProxyAppX.app` 拖到「应用程序」文件夹（**必须在 /Applications 下**，网络扩展才能激活），然后打开
3. 按 App 概览页的引导安装网络扩展，在「系统设置 › 通用 › 登录项与扩展 › 网络扩展」中允许，并允许添加代理配置

系统要求：macOS 15 及以上。

## 功能

- **按应用分流**：支持 `.app` 和任意可执行文件；会自动识别应用的 helper 子进程（Chrome Helper、Electron Helper 等）
- **三种动作**：代理（选择服务器）/ 直连 / 阻断
- **代理协议**：SOCKS5（无认证、用户名密码、UDP ASSOCIATE）和 HTTP CONNECT（Basic 认证）
- **防泄漏**：代理不可用时默认阻断；UDP 默认阻断，迫使浏览器从 QUIC 回落到 TCP；会把域名交给代理远程解析
- **排除模式**：默认所有应用都走代理，只让指定应用直连
- **与 Clash / FlClash 等 TUN 工具共存**：见[下文](#与-clash--flclash-等-tun-工具共存)
- **监控**：实时连接、上下行速率、日志，以及「未匹配的应用」（帮你发现应该加规则的进程）
- **菜单栏**：一键开关；支持登录时启动；配置可导入导出

## 原理

```
ProxyAppX.app（SwiftUI）──安装──▶ 系统扩展（NETransparentProxyProvider，以 root 运行）
     │  配置 + IPC                     │ 拦截所有出站 TCP/UDP flow
     └────────────────────────────────▶ │ 按 flow 的来源进程（签名标识 / audit token → 路径）匹配规则
                                        ├─ 直连：交还给系统（零开销）
                                        ├─ 阻断：拒绝连接
                                        └─ 代理：经 SOCKS5 / HTTP CONNECT 转发
```

## 目录结构

```
project.yml                     XcodeGen 工程描述（.xcodeproj 由它生成，不入库）
Config/                         xcconfig：Bundle ID 前缀、签名（Signing.xcconfig 不入库）
Packages/ProxyAppXCore/         共享核心库：数据模型、规则引擎、SOCKS5 / HTTP 协议、连接器、IPC（带测试）
ProxyAppXExtension/             系统扩展：透明代理 Provider、TCP/UDP 转发、进程识别、连接统计
ProxyAppX/                      主 App：SwiftUI 界面、菜单栏、扩展安装、配置存储（钥匙串）
scripts/build.sh                构建 / 签名 / 安装脚本
scripts/release.sh              发布脚本：Developer ID 导出、公证、打包
scripts/dev-socks5.py           会打印每个连接的 SOCKS5 测试服务器
docs/PRD.md                     产品需求文档
```

## 构建与运行

### 1. 准备

- macOS 15+、Xcode 16+（当前在 Xcode 27.2 上验证过）
- `brew install xcodegen`
- 加入 **Apple Developer Program**（系统扩展和 Network Extension 都需要付费开发者账号）

### 2. 配置签名

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

编辑 `Config/Signing.xcconfig`，填入 `DEVELOPMENT_TEAM`。如果 `com.proxyappx` 这个前缀已被别人占用，就改 `BUNDLE_ID_PREFIX`。

**开发调试（推荐）**：使用自动签名。先在 Xcode › Settings › Accounts 里登录 Apple ID，构建时 Xcode 会自动注册 App ID（包含 Network Extensions、System Extension 能力）并生成描述文件。

**Developer ID 分发**：直接运行 `scripts/release.sh` 即可（见[发布](#发布)），Xcode 会自动生成 Developer ID 描述文件并提交公证。如果想手动管理，就在 developer.apple.com 创建两个 App ID（`<前缀>.app` 和 `<前缀>.app.extension`），勾选 *Network Extensions* 和 *System Extension*，再创建对应的 Developer ID 描述文件，然后按 `Signing.example.xcconfig` 里的方案 B 填写。

### 3. 构建并安装

```bash
scripts/build.sh
```

脚本会生成工程、签名构建，然后安装到 `/Applications/ProxyAppX.app` 并打开它。系统扩展**只能从 /Applications 激活**。

只检查能否编译、运行测试（不需要签名）：

```bash
scripts/build.sh check
```

也可以先运行 `xcodegen generate`，再用 Xcode 打开 `ProxyAppX.xcodeproj` 开发。

### 4. 首次使用

1. 在概览页点击「安装」网络扩展，然后到 **系统设置 › 通用 › 登录项与扩展 › 网络扩展** 里允许 ProxyAppX
2. 首次启用时，系统会询问是否允许「添加代理配置」，选择允许
3. 在「代理服务器」中添加服务器，点击「测试」确认可用
4. 在「应用规则」中添加应用，选择代理服务器
5. 打开开关

验证：给 `/usr/bin/curl` 添加一条代理规则，然后

```bash
curl https://ifconfig.me
```

应该返回代理的出口 IP，而浏览器访问同一地址仍显示本机 IP。

## 发布

```bash
scripts/release.sh
```

脚本会做 Release 归档，用 Developer ID 导出并提交 Apple 公证，等公证通过后把装订好票据的 App 打包成 `build/release/ProxyAppX-<版本>.zip`，并生成 SHA-256。需要先在 Xcode 中登录开发者账号：导出时会自动生成 Developer ID 描述文件，并用这个账号提交公证。版本号在 `project.yml` 的 `MARKETING_VERSION` 中修改。

## 调试

查看扩展日志：

```bash
log stream --predicate 'subsystem == "com.proxyappx.extension"' --level info
```

查看系统扩展状态：

```bash
systemextensionsctl list
```

扩展更新后，重新运行 `scripts/build.sh` 即可：脚本每次会使用新的构建号，App 启动时发现自带的扩展与已安装的版本不同，就会自动替换（无需重新批准），并在系统断开会话后自动重连。

端到端自测：启动一个会打印每个连接的本地 SOCKS5 测试服务器，在 App 中添加服务器 `127.0.0.1:1080`，再给 `/usr/bin/curl` 加一条代理规则：

```bash
python3 scripts/dev-socks5.py 1080
```

然后执行 `curl https://example.com`，测试服务器会打印 `✓ CONNECT example.com:443`；没有规则的应用不会出现在这里。

核心库测试（规则匹配、协议编解码、对本地 SOCKS5 / HTTP 测试服务器的端到端握手、UDP 转发）：

```bash
cd Packages/ProxyAppXCore && swift test
```

## 与 Clash / FlClash 等 TUN 工具共存

两者可以同时开启。ProxyAppX 在 socket 层先截获连接；它放行的流量（包括 DNS）会交还给系统网络栈，再照常按路由进入 TUN 工具：

```
应用 → ① ProxyAppX（按应用判定）
          ├─ 放行（直连 / DNS / 未命中）→ 路由 → utun → ② Clash（DNS 劫持、fake-IP、Clash 规则）
          ├─ 阻断
          └─ 代理 → 扩展连接上游代理（上游在本机：直达；上游在远程：默认也会经过 utun）
```

为此，ProxyAppX 做了这些处理（在「设置 › 与其他 VPN / TUN 共存」中可以调整）：

- **绑定网卡的连接直连**（默认开）：Clash 内核把自己的连接绑定到物理网卡来绕开 TUN，这类连接一律放行，排除模式下也不会回环
- **fake-IP 兜底**（默认开）：目标是 198.18.x.x 又拿不到域名、上游在远程时，交给 Clash 处理；有域名时总是把域名交给上游
- **上游连接绕过其他 VPN / TUN**（默认关）：开启后扩展直接经物理网卡连接远程代理，不会被 Clash 二次代理。也可以改在 Clash 规则里放行扩展：`PROCESS-NAME,com.proxyappx.app.extension,DIRECT`
- App 会检测接管公网流量的 utun 网卡和 fake-IP 模式，在可能二次代理时给出提示

注意：Clash 开启「系统代理」模式时，遵守系统代理的应用会直连 `127.0.0.1:7890`，ProxyAppX 对这些应用的规则不会生效；建议改用 TUN 模式。

## 已知限制

- **DNS 不经过代理**：系统会把应用的 DNS 查询（53 端口）归属到该应用，为了不影响解析，DNS 一律直连。开启「优先把域名交给代理解析」（默认开启）后，连接本身仍以域名形式交给代理，但本地仍会发生一次 DNS 查询
- Safari、后台下载等由系统共享进程代发的流量，能否精确归属取决于系统的归因
- 排除模式下，如果本机的代理客户端（Clash 等）没有把自己的连接绑定到网卡（例如没开 TUN 模式），必须给它加一条「直连」规则（App 会给出提示）
- UDP 只有 SOCKS5 服务器支持 UDP ASSOCIATE 时才能转发
- 界面目前只有简体中文

## 卸载

在 App 的「设置 › 网络扩展」中点击「卸载扩展」，然后删除 `/Applications/ProxyAppX.app`。配置文件位于 `~/Library/Application Support/ProxyAppX/`，代理密码保存在登录钥匙串中（服务名 `ProxyAppX.ProxyServer`）。
