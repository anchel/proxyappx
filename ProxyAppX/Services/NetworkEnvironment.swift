import Darwin
import Foundation
import Network
import Observation
import ProxyAppXCore

/// 检测是否有其他 VPN / TUN 工具（Clash、FlClash、Surge、公司 VPN 等）正在接管公网流量。
@MainActor
@Observable
final class NetworkEnvironment {
    struct Tunnel: Equatable {
        /// 承载公网流量的网卡，例如 utun4
        let interface: String
        /// 该网卡的 IPv4 地址，例如 198.18.0.1
        let address: String?
        /// 地址位于 198.18.0.0/15：多半是 Clash / Surge 类工具的 fake-IP 模式
        let isFakeIP: Bool

        var summary: String {
            let addr = address.map { " (\($0))" } ?? ""
            return isFakeIP
                ? String(localized: "\(interface)\(addr) is carrying public traffic: a fake-IP TUN, probably Clash, FlClash or Surge")
                : String(localized: "\(interface)\(addr) is carrying public traffic: a VPN or TUN tool")
        }
    }

    private(set) var tunnel: Tunnel?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: .main)
        // TUN 工具开关时不一定触发路径变化，定期再查一次。
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let detected = Self.detect()
            await MainActor.run { [weak self] in
                if self?.tunnel != detected { self?.tunnel = detected }
            }
        }
    }

    // MARK: 检测

    nonisolated static func detect() -> Tunnel? {
        // TUN 工具通常用 0/1 + 128/1 等拆分路由接管流量，默认路由仍指向物理网卡，
        // 所以直接查询一个公网地址实际走哪块网卡。
        guard let iface = routeInterface(for: "1.1.1.1"),
              ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: { iface.hasPrefix($0) }) else { return nil }
        let address = ipv4Address(of: iface)
        let fake = address.map { TargetAddress(host: $0, port: 0).isFakeIP } ?? false
        return Tunnel(interface: iface, address: address, isFakeIP: fake)
    }

    nonisolated private static func routeInterface(for ip: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface" { return parts[1] }
        }
        return nil
    }

    nonisolated private static func ipv4Address(of name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
