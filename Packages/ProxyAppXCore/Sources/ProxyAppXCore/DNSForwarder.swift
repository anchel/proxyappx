import Foundation

/// A DNS server reachable from the proxy. An IP literal also avoids a bootstrap lookup.
public struct DNSResolver: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let cloudflare = DNSResolver(rawValue: "1.1.1.1")!

    public init?(rawValue: String) {
        let host = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = TargetAddress(host: host, port: RuleEngine.dnsPort)
        guard !host.contains("%") else { return nil }
        switch target.kind {
        case .ipv4(let bytes): self.rawValue = IPAddressParser.format(ipv4: bytes)
        case .ipv6(let bytes): self.rawValue = IPAddressParser.format(ipv6: bytes)
        case .domain: return nil
        }
    }

    public var target: TargetAddress { TargetAddress(host: rawValue, port: RuleEngine.dnsPort) }
}

public enum DNSForwarder {
    /// One UDP transaction per TCP tunnel. This keeps IDs isolated across concurrent app flows.
    public static func reply(to query: Data, resolver: TargetAddress, via server: ProxyServer,
                             timeout: TimeInterval, avoidTunnels: Bool) async throws -> Data {
        guard (12...65535).contains(query.count), query[query.startIndex + 2] & 0x80 == 0 else {
            throw malformed()
        }
        let conn = try await ProxyConnector.connect(to: resolver, via: .proxy(server), timeout: timeout,
                                                    avoidTunnels: avoidTunnels)
        defer { conn.cancel() }
        let deadline = Deadline(seconds: timeout) { conn.cancel() }
        do {
            let length = query.count
            try await conn.send(Data([UInt8(length >> 8), UInt8(truncatingIfNeeded: length)]) + query)
            let prefix = try await conn.readExactly(2)
            let response = try await conn.readExactly(Int(prefix[0]) << 8 | Int(prefix[1]))
            guard deadline.disarm() else { throw ProxyError.timeout }
            guard response.count >= 12, response.prefix(2) == query.prefix(2), response[2] & 0x80 != 0 else {
                throw malformed()
            }
            return try udpReply(response, query: query)
        } catch {
            throw deadline.disarm() ? error : ProxyError.timeout
        }
    }

    private static func malformed() -> ProxyError {
        .protocolViolation(L10n.t("Invalid DNS message", "DNS 报文无效"))
    }

    /// Respect the client's advertised EDNS receive size. When a reply exceeds it,
    /// return the original question with TC set so the client can retry over TCP.
    static func udpReply(_ response: Data, query: Data) throws -> Data {
        guard response.count > 512 else { return response }
        let bytes = [UInt8](query)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        var offset = 12
        func skipName() throws {
            while offset < bytes.count {
                let size = Int(bytes[offset])
                offset += 1
                if size == 0 { return }
                if size & 0xc0 == 0xc0, offset < bytes.count {
                    offset += 1
                    return
                }
                guard size <= 63, size <= bytes.count - offset else { throw malformed() }
                offset += size
            }
            throw malformed()
        }

        guard bytes.count >= 12 else { throw malformed() }
        for _ in 0..<word(4) {
            try skipName()
            guard offset + 4 <= bytes.count else { throw malformed() }
            offset += 4 // QTYPE, QCLASS
        }
        let questionsEnd = offset
        var limit = 512
        let recordsBeforeAdditional = word(6) + word(8)
        for index in 0..<(recordsBeforeAdditional + word(10)) {
            try skipName()
            guard offset + 10 <= bytes.count else { throw malformed() }
            if index >= recordsBeforeAdditional, word(offset) == 41 { // OPT pseudo-record
                limit = max(512, min(word(offset + 2), 65507))
            }
            offset += 10 + word(offset + 8)
            guard offset <= bytes.count else { throw malformed() }
        }
        guard response.count > limit else { return response }
        var truncated = Data(response.prefix(4))
        truncated[2] |= 0x02
        let includeQuestions = questionsEnd <= limit
        truncated.append(contentsOf: includeQuestions ? Array(bytes[4..<6]) : [0, 0])
        truncated.append(Data(repeating: 0, count: 6)) // ANCOUNT, NSCOUNT, ARCOUNT
        if includeQuestions { truncated.append(contentsOf: bytes[12..<questionsEnd]) }
        return truncated
    }
}
