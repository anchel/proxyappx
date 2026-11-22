English | [简体中文](README.zh-CN.md)

# ProxyAppX — Per-App Proxy for macOS

Pick an app and send **all of its network traffic** through a SOCKS5 or HTTP proxy of your choice, while every other app keeps connecting directly. This works even for apps that ignore the system proxy settings: Electron apps, games, and command-line tools such as `curl` and `git`.

Full product requirements (in Chinese): [docs/PRD.md](docs/PRD.md).

## Download and install

1. Download the latest `ProxyAppX-<version>.dmg` from [Releases](https://github.com/anchel/proxyappx/releases). The app inside is signed with Developer ID and notarized by Apple.
2. Open the DMG and drag `ProxyAppX` onto the `Applications` shortcut next to it. **It must live in /Applications**, or the network extension cannot be activated. Then open it from Applications.
3. Follow the Overview page to install the network extension, allow it in **System Settings › General › Login Items & Extensions › Network Extensions**, and allow the proxy configuration when macOS asks.

Requires macOS 15 or later.

## Features

- **Per-app routing**: works with `.app` bundles and any executable, and automatically covers an app's helper processes (Chrome Helper, Electron Helper, and so on)
- **Three actions**: Proxy (through a chosen server), Direct, or Block
- **Proxy protocols**: SOCKS5 (no auth, username/password, UDP ASSOCIATE) and HTTP CONNECT (Basic auth)
- **Leak protection**: connections fail closed when the proxy is down; UDP is blocked by default, and apps that support fallback can retry over TCP; hostnames are sent to the proxy for remote resolution
- **Exclusion mode**: send every app through the proxy except the ones you mark as Direct
- **Coexists with Clash / FlClash and other TUN tools**: see [below](#coexisting-with-clash--flclash-and-other-tun-tools)
- **Monitoring**: live connections, upload/download rates, logs, and an "Unmatched Apps" page that surfaces processes you may want to add rules for
- **Menu bar**: one-click on/off, launch at login, configuration import/export
- **English and Simplified Chinese UI**: follows the system language, or pick one under Settings › General › Language

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
Makefile                        Entry point for all build commands (run `make` to list them)
scripts/build.sh                Build / sign / install (make build, install, check)
scripts/release.sh              Release: Developer ID export, notarization (make release)
scripts/make-dmg.sh             Packages the notarized app as a DMG (make dmg)
scripts/publish.sh              Tags the version and publishes the GitHub release (make publish)
scripts/dev-socks5.py           Test SOCKS5 server that prints every connection
docs/release-notes/             Release notes, one file per version
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

**Developer ID distribution**: just run `make release` (see [Releasing](#releasing)); Xcode creates the Developer ID profiles and submits the app for notarization. To manage this by hand instead, create two App IDs on developer.apple.com (`<prefix>.app` and `<prefix>.app.extension`) with *Network Extensions* and *System Extension* enabled, create matching Developer ID profiles, and fill in option B in `Signing.example.xcconfig`.

### 3. Build and install

All build commands go through `make`; run `make` on its own to list them.

```bash
make install
```

This generates the project, builds and signs it, installs it to `/Applications/ProxyAppX.app`, and opens it. System extensions **can only be activated from /Applications**. Add `CONFIG=Release` for a Release build, or use `make build` to build without installing.

To only check that everything compiles and run the tests (no signing needed):

```bash
make check
```

You can also run `make project` and work in `ProxyAppX.xcodeproj` with Xcode.

### 4. First run

1. On the Overview page, click Install for the network extension, then allow ProxyAppX in **System Settings › General › Login Items & Extensions › Network Extensions**
2. The first time you turn it on, macOS asks to allow adding a proxy configuration; allow it
3. Under Proxy Servers, add a server and click Test to make sure it works
4. Under App Rules, add an app and pick the proxy server
5. Turn on the switch

To verify, add a proxy rule for `/usr/bin/curl`, then run:

```bash
curl https://ifconfig.me
```

It should print the proxy's exit IP, while a browser visiting the same address still shows your own IP.

## Releasing

1. Set the new version in `MARKETING_VERSION` in `project.yml`, write the release notes in `docs/release-notes/v<version>.md`, then commit and push.
2. Build the installer:

   ```bash
   make release
   ```

   This makes a Release archive, exports it with Developer ID signing, submits it to Apple for notarization, waits for the ticket, and packages the stapled app as `build/release/ProxyAppX-<version>.dmg` with a SHA-256 checksum. Sign in to your developer account in Xcode first: the export creates the Developer ID profiles and notarizes with that account.
3. Publish it:

   ```bash
   make publish
   ```

   This checks that the DMG was built from the current, pushed commit, tags `v<version>`, and creates the GitHub release with the DMG and its checksum (requires `gh auth login`). If the version is already published, it replaces the DMG and checksum instead.

The DMG is signed with Developer ID, notarized and stapled as well. That needs notary credentials in the keychain, saved once with an app-specific password for your Apple ID (or an App Store Connect API key):

```bash
xcrun notarytool store-credentials proxyappx-notary --team-id <Team ID>
```

Then set `NOTARY_PROFILE = proxyappx-notary` in `Config/Signing.xcconfig`. Without it, the DMG is left unsigned (the app inside is still notarized). To re-sign an already published version's DMG, run `make dmg` and then `make publish`, which replaces the release's DMG and checksum.

## Debugging

Stream the extension's logs:

```bash
log stream --predicate 'subsystem == "com.proxyappx.extension"' --level info
```

Check the system extension's state:

```bash
systemextensionsctl list
```

After changing the extension, just run `make install` again. Every build gets a new build number; on launch the app notices that its bundled extension differs from the installed one, replaces it (no re-approval needed), and reconnects once macOS drops the old session.

End-to-end check: start a local SOCKS5 test server that prints every connection, add server `127.0.0.1:1080` in the app, and add a proxy rule for `/usr/bin/curl`:

```bash
python3 scripts/dev-socks5.py 1080
```

Then run `curl https://example.com`; the test server prints `✓ CONNECT example.com:443`. Apps without a rule never show up there.

To check plain DNS, add the same proxy rule for `/usr/bin/dig` and check that “Route app DNS queries through their proxy” is on. Run `dig @192.0.2.53 example.com A` and `dig +tcp @192.0.2.53 example.com A` to exercise UDP and TCP. The address in these commands is a documentation IP. Both queries should return an answer, and the proxy log should show the configured resolver (initially `1.1.1.1:53`). To check an app that uses the system resolver, open an uncached name in that app and compare the source app in Connections with a capture of local DNS traffic.

Core library tests (rule matching, protocol codecs, end-to-end handshakes against in-process SOCKS5 / HTTP test servers, UDP relay):

```bash
cd Packages/ProxyAppXCore && swift test
```

## Coexisting with Clash / FlClash and other TUN tools

Both can run at the same time. ProxyAppX intercepts connections at the socket layer first. Traffic it passes through (including DNS for apps routed directly) follows the system routes into the TUN tool as usual:

```
App → ① ProxyAppX (decides per app)
         ├─ pass through (Direct / DNS / no rule) → routing → utun → ② Clash (DNS hijack, fake-IP, Clash rules)
         ├─ Block
         └─ Proxy → the extension connects to the upstream proxy
                    (local upstream: straight there; remote upstream: also goes through utun by default)
```

ProxyAppX handles the cases where the two would interfere. You can adjust these under Settings › Coexisting with Other VPN / TUN:

- **Bound flows go direct** (on by default): Clash's core binds its own connections to the physical interface to escape its TUN. These flows are always passed through, so exclusion mode cannot create a loop.
- **Fake-IP fallback** (on by default): when the destination is a 198.18.x.x fake IP, no hostname is available, and the upstream is remote, the connection is handed back to Clash. Whenever a hostname is available, it is always sent upstream.
- **Upstream avoids other VPN / TUN** (off by default): the extension reaches remote proxies over the physical interface, so Clash does not proxy that traffic a second time. Alternatively, let the extension through in your Clash rules: `PROCESS-NAME,com.proxyappx.app.extension,DIRECT`
- The app detects a utun interface carrying public traffic and fake-IP mode, and warns you when traffic might be proxied twice.

Note: with Clash in "system proxy" mode, apps that honor the system proxy connect straight to `127.0.0.1:7890`, so ProxyAppX rules for those apps have no effect. Use TUN mode instead.

## Known limitations

- **Per-app DNS**. “Route app DNS queries through their proxy” is on by default in Settings › Connections. The resolver defaults to `1.1.1.1` and accepts a custom IP. When the extension receives a plain DNS flow (UDP/TCP 53) attributable to an app routed through a proxy, it connects to the resolver through that app’s SOCKS5 or HTTP CONNECT proxy on **TCP port 53**. The proxy must permit this port. Intercepted queries fail closed, including when other connections allow direct fallback. Use a resolver that knows your private domains if needed.
- Queries attributed only to the system resolver, loopback DNS and exempt interface-bound connections keep their original resolution path. App-managed encrypted DNS follows ordinary connection rules. “Send hostnames to the proxy for resolution” independently controls the destination sent for subsequent TCP connections.
- Traffic sent on an app's behalf by shared system processes (Safari, background downloads) is attributed however macOS attributes it, which may not match the app.
- In exclusion mode, if a local proxy client (Clash and the like) does not bind its own connections to an interface (for example, TUN mode is off), add a Direct rule for it; the app warns you about this.
- UDP can only be relayed through SOCKS5 servers that support UDP ASSOCIATE.

## Uninstall

In the app, go to Settings › Network Extension and click Uninstall Extension, then delete `/Applications/ProxyAppX.app`. Configuration lives in `~/Library/Application Support/ProxyAppX/`; proxy passwords are stored in the login keychain under the service name `ProxyAppX.ProxyServer`.
