English | [简体中文](README.zh-CN.md)

# ProxyAppX — Per-App Proxy for macOS

Pick an app and send **all of its network traffic** through a SOCKS5 or HTTP proxy of your choice, while every other app keeps connecting directly. This works even for apps that ignore the system proxy settings: Electron apps, games, and command-line tools such as `curl` and `git`.

Full product requirements (in Chinese): [docs/PRD.md](docs/PRD.md).

> The app's interface is currently in Simplified Chinese. UI labels below are given in English with the Chinese text in parentheses.

## Download and install

1. Download the latest `ProxyAppX-<version>.zip` from [Releases](https://github.com/anchel/proxyappx/releases). It is signed with Developer ID and notarized by Apple.
2. Unzip it and drag `ProxyAppX.app` into the Applications folder. **It must live in /Applications**, or the network extension cannot be activated. Then open it.
3. Follow the Overview page to install the network extension, allow it in **System Settings › General › Login Items & Extensions › Network Extensions**, and allow the proxy configuration when macOS asks.

Requires macOS 15 or later.

## Features

- **Per-app routing**: works with `.app` bundles and any executable, and automatically covers an app's helper processes (Chrome Helper, Electron Helper, and so on)
- **Three actions**: Proxy (through a chosen server), Direct, or Block
- **Proxy protocols**: SOCKS5 (no auth, username/password, UDP ASSOCIATE) and HTTP CONNECT (Basic auth)
- **Leak protection**: connections fail closed when the proxy is down; UDP is blocked by default so browsers fall back from QUIC to TCP; hostnames are sent to the proxy for remote resolution
- **Exclusion mode**: send every app through the proxy except the ones you mark as Direct
- **Coexists with Clash / FlClash and other TUN tools**: see [below](#coexisting-with-clash--flclash-and-other-tun-tools)
- **Monitoring**: live connections, upload/download rates, logs, and an "Unmatched apps" (未匹配的应用) page that surfaces processes you may want to add rules for
- **Menu bar**: one-click on/off, launch at login, configuration import/export

## How it works

```
ProxyAppX.app (SwiftUI) ──installs──▶ System extension (NETransparentProxyProvider, runs as root)
     │  config + IPC                     │ sees every outbound TCP/UDP flow
     └──────────────────────────────────▶ │ matches rules by the flow's source process (signing ID / audit token → path)
                                          ├─ Direct: hands the flow back to the system (zero overhead)
                                          ├─ Block: refuses the connection
                                          └─ Proxy: relays through SOCKS5 / HTTP CONNECT
```

## Repository layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated and not committed)
Config/                         xcconfigs: bundle ID prefix, signing (Signing.xcconfig is not committed)
Packages/ProxyAppXCore/         Shared core: models, rule engine, SOCKS5 / HTTP clients, connector, IPC (with tests)
ProxyAppXExtension/             System extension: transparent proxy provider, TCP/UDP relays, process lookup, stats
ProxyAppX/                      Main app: SwiftUI UI, menu bar, extension install, config storage (Keychain)
scripts/build.sh                Build / sign / install
scripts/release.sh              Release: Developer ID export, notarization, packaging
scripts/dev-socks5.py           Test SOCKS5 server that prints every connection
docs/PRD.md                     Product requirements (Chinese)
```

## Building from source

### 1. Prerequisites

- macOS 15+, Xcode 16+ (verified on Xcode 27.2)
- `brew install xcodegen`
- An **Apple Developer Program** membership: system extensions and Network Extension both require a paid account

### 2. Configure signing

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

Edit `Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM`. If the `com.proxyappx` prefix is already taken, change `BUNDLE_ID_PREFIX`.

**Development (recommended)**: use automatic signing. Sign in under Xcode › Settings › Accounts; on build, Xcode registers the App IDs (with the Network Extensions and System Extension capabilities) and creates the provisioning profiles.

**Developer ID distribution**: just run `scripts/release.sh` (see [Releasing](#releasing)); Xcode creates the Developer ID profiles and submits the app for notarization. To manage this by hand instead, create two App IDs on developer.apple.com (`<prefix>.app` and `<prefix>.app.extension`) with *Network Extensions* and *System Extension* enabled, create matching Developer ID profiles, and fill in option B in `Signing.example.xcconfig`.

### 3. Build and install

```bash
scripts/build.sh
```

The script generates the project, builds and signs it, installs it to `/Applications/ProxyAppX.app`, and opens it. System extensions **can only be activated from /Applications**.

To only check that everything compiles and run the tests (no signing needed):

```bash
scripts/build.sh check
```

You can also run `xcodegen generate` and work in `ProxyAppX.xcodeproj` with Xcode.

### 4. First run

1. On the Overview page, click Install (安装) for the network extension, then allow ProxyAppX in **System Settings › General › Login Items & Extensions › Network Extensions**
2. The first time you turn it on, macOS asks to allow adding a proxy configuration; allow it
3. Under Proxy Servers (代理服务器), add a server and click Test (测试) to make sure it works
4. Under App Rules (应用规则), add an app and pick the proxy server
5. Turn on the switch

To verify, add a proxy rule for `/usr/bin/curl`, then run:

```bash
curl https://ifconfig.me
```

It should print the proxy's exit IP, while a browser visiting the same address still shows your own IP.

## Releasing

```bash
scripts/release.sh
```

The script makes a Release archive, exports it with Developer ID signing, submits it to Apple for notarization, waits for the ticket, and packages the stapled app as `build/release/ProxyAppX-<version>.zip` with a SHA-256 checksum. Sign in to your developer account in Xcode first: the export creates the Developer ID profiles and notarizes with that account. Bump the version via `MARKETING_VERSION` in `project.yml`.

## Debugging

Stream the extension's logs:

```bash
log stream --predicate 'subsystem == "com.proxyappx.extension"' --level info
```

Check the system extension's state:

```bash
systemextensionsctl list
```

After changing the extension, just run `scripts/build.sh` again. Every build gets a new build number; on launch the app notices that its bundled extension differs from the installed one, replaces it (no re-approval needed), and reconnects once macOS drops the old session.

End-to-end check: start a local SOCKS5 test server that prints every connection, add server `127.0.0.1:1080` in the app, and add a proxy rule for `/usr/bin/curl`:

```bash
python3 scripts/dev-socks5.py 1080
```

Then run `curl https://example.com`; the test server prints `✓ CONNECT example.com:443`. Apps without a rule never show up there.

Core library tests (rule matching, protocol codecs, end-to-end handshakes against in-process SOCKS5 / HTTP test servers, UDP relay):

```bash
cd Packages/ProxyAppXCore && swift test
```

## Coexisting with Clash / FlClash and other TUN tools

Both can run at the same time. ProxyAppX intercepts connections at the socket layer first; whatever it lets through (including DNS) goes back to the system network stack and then follows the routing table into the TUN tool as usual:

```
App → ① ProxyAppX (decides per app)
         ├─ pass through (Direct / DNS / no rule) → routing → utun → ② Clash (DNS hijack, fake-IP, Clash rules)
         ├─ Block
         └─ Proxy → the extension connects to the upstream proxy
                    (local upstream: straight there; remote upstream: also goes through utun by default)
```

ProxyAppX handles the cases where the two would interfere. You can adjust these under Settings › Coexisting with other VPN / TUN (设置 › 与其他 VPN / TUN 共存):

- **Bound flows go direct** (on by default): Clash's core binds its own connections to the physical interface to escape its TUN. These flows are always passed through, so exclusion mode cannot create a loop.
- **Fake-IP fallback** (on by default): when the destination is a 198.18.x.x fake IP, no hostname is available, and the upstream is remote, the connection is handed back to Clash. Whenever a hostname is available, it is always sent upstream.
- **Upstream avoids other VPN / TUN** (off by default): the extension reaches remote proxies over the physical interface, so Clash does not proxy that traffic a second time. Alternatively, let the extension through in your Clash rules: `PROCESS-NAME,com.proxyappx.app.extension,DIRECT`
- The app detects a utun interface carrying public traffic and fake-IP mode, and warns you when traffic might be proxied twice.

Note: with Clash in "system proxy" mode, apps that honor the system proxy connect straight to `127.0.0.1:7890`, so ProxyAppX rules for those apps have no effect. Use TUN mode instead.

## Known limitations

- **DNS does not go through the proxy**: macOS attributes an app's DNS queries (port 53) to the app itself, so to keep name resolution working, DNS always goes direct. With "Send hostnames to the proxy for resolution" (优先把域名交给代理解析, on by default), the connection itself still reaches the proxy by hostname, but a local DNS query still happens.
- Traffic sent on an app's behalf by shared system processes (Safari, background downloads) is attributed however macOS attributes it, which may not match the app.
- In exclusion mode, if a local proxy client (Clash and the like) does not bind its own connections to an interface (for example, TUN mode is off), add a Direct rule for it; the app warns you about this.
- UDP can only be relayed through SOCKS5 servers that support UDP ASSOCIATE.
- The interface is currently available in Simplified Chinese only.

## Uninstall

In the app, go to Settings › Network Extension (设置 › 网络扩展) and click Uninstall extension (卸载扩展), then delete `/Applications/ProxyAppX.app`. Configuration lives in `~/Library/Application Support/ProxyAppX/`; proxy passwords are stored in the login keychain under the service name `ProxyAppX.ProxyServer`.
