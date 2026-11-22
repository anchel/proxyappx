import Foundation
import Network
import NetworkExtension
import ProxyAppXCore

// MARK: - NEAppProxyFlow 的 async 封装

extension NEAppProxyTCPFlow {
    /// 读取数据；返回空 Data 表示应用已关闭写方向。
    func readChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            readData { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
            }
        }
    }

    func writeChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            write(data) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

extension NEAppProxyFlow {
    func openFlow() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            open(withLocalFlowEndpoint: nil) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// 拒绝连接：应用侧会收到 "Connection refused"。
    func reject() {
        let error = NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue)
        closeReadWithError(error)
        closeWriteWithError(error)
    }

    func closeBoth(_ error: Error? = nil) {
        closeReadWithError(error)
        closeWriteWithError(error)
    }
}

/// 记录首个错误（两个方向的泵可能同时出错）。
private final class FirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    private var sealed = false

    func set(_ error: Error) {
        lock.lock()
        if message == nil && !sealed { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        lock.unlock()
    }

    /// 之后的错误（主动关闭引起的取消）不再记录。
    func seal() {
        lock.lock()
        sealed = true
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

// MARK: - TCP

/// 一个 TCP flow 与上游连接（代理或直连）之间的双向转发。
final class TCPRelay: @unchecked Sendable {
    struct Plan {
        /// 交给代理的目标（可能是域名）
        let proxyTarget: TargetAddress
        /// 原始目标 IP（直连或回落直连时使用）
        let directTarget: TargetAddress
        let upstream: Upstream
        let failurePolicy: FailurePolicy
        let timeout: TimeInterval
    }

    private let flow: NEAppProxyTCPFlow
    private let id: UInt64
    private let plan: Plan
    private let tracker: ConnectionTracker
    private let firstError = FirstError()

    init(flow: NEAppProxyTCPFlow, id: UInt64, plan: Plan, tracker: ConnectionTracker) {
        self.flow = flow
        self.id = id
        self.plan = plan
        self.tracker = tracker
    }

    func start() {
        Task.detached(priority: .userInitiated) { [self] in
            await run()
        }
    }

    private func run() async {
        let conn: AsyncConnection
        do {
            conn = try await establish()
        } catch {
            firstError.set(error)
            flow.reject()
            tracker.finish(id, error: firstError.value)
            return
        }

        do {
            try await flow.openFlow()
        } catch {
            firstError.set(error)
            conn.cancel()
            flow.closeBoth(error)
            tracker.finish(id, error: firstError.value)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pumpAppToUpstream(conn) }
            group.addTask { await self.pumpUpstreamToApp(conn) }
        }

        conn.cancel()
        flow.closeBoth()
        tracker.finish(id, error: firstError.value)
    }

    private func establish() async throws -> AsyncConnection {
        switch plan.upstream {
        case .direct:
            return try await ProxyConnector.connect(to: plan.directTarget, via: .direct, timeout: plan.timeout)
        case let .proxy(server):
            do {
                return try await ProxyConnector.connect(to: plan.proxyTarget, via: .proxy(server), timeout: plan.timeout)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                guard plan.failurePolicy == .direct else {
                    tracker.log(.warning, "代理 \(server.name) 连接 \(plan.proxyTarget) 失败：\(reason)")
                    throw error
                }
                tracker.log(.warning, "代理 \(server.name) 失败（\(reason)），\(plan.directTarget) 回落直连")
                tracker.markFallback(id)
                return try await ProxyConnector.connect(to: plan.directTarget, via: .direct, timeout: plan.timeout)
            }
        }
    }

    /// 应用 → 上游
    private func pumpAppToUpstream(_ conn: AsyncConnection) async {
        do {
            while true {
                let data = try await flow.readChunk()
                if data.isEmpty {
                    try await conn.sendEOF()
                    return
                }
                try await conn.send(data)
                tracker.addBytes(id, up: data.count)
            }
        } catch {
            firstError.set(error)
            conn.cancel()
            flow.closeBoth(error)
        }
    }

    /// 上游 → 应用
    private func pumpUpstreamToApp(_ conn: AsyncConnection) async {
        do {
            while let data = try await conn.receive() {
                try await flow.writeChunk(data)
                tracker.addBytes(id, down: data.count)
            }
            // 上游发送了 FIN：关闭应用侧的读方向（应用收到 EOF），写方向保持，支持半关闭。
            flow.closeWriteWithError(nil)
        } catch {
            firstError.set(error)
            conn.cancel()
            flow.closeBoth(error)
        }
    }
}

// MARK: - UDP

/// 一个 UDP flow 经 SOCKS5 UDP ASSOCIATE 转发。
final class UDPRelay: @unchecked Sendable {
    private let flow: NEAppProxyUDPFlow
    private let id: UInt64
    private let server: ProxyServer
    private let timeout: TimeInterval
    private let tracker: ConnectionTracker
    private let firstError = FirstError()

    init(flow: NEAppProxyUDPFlow, id: UInt64, server: ProxyServer, timeout: TimeInterval, tracker: ConnectionTracker) {
        self.flow = flow
        self.id = id
        self.server = server
        self.timeout = timeout
        self.tracker = tracker
    }

    func start() {
        Task.detached(priority: .userInitiated) { [self] in
            await run()
        }
    }

    private func run() async {
        let assoc: SOCKS5UDPAssociation
        do {
            assoc = try await SOCKS5UDPAssociation.open(server: server, timeout: timeout)
        } catch {
            firstError.set(error)
            tracker.log(.warning, "UDP 关联 \(server.name) 失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            flow.reject()
            tracker.finish(id, error: firstError.value)
            return
        }

        do {
            try await flow.openFlow()
        } catch {
            firstError.set(error)
            assoc.close()
            flow.closeBoth(error)
            tracker.finish(id, error: firstError.value)
            return
        }

        // 任意一个任务结束（应用关闭、代理关闭关联、出错）即整体结束。
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pumpAppToRelay(assoc) }
            group.addTask { await self.pumpRelayToApp(assoc) }
            group.addTask { await assoc.waitForControlClose() }
            await group.next()
            firstError.seal()
            assoc.close()
            flow.closeBoth()
            group.cancelAll()
        }
        tracker.finish(id, error: firstError.value)
    }

    private func pumpAppToRelay(_ assoc: SOCKS5UDPAssociation) async {
        while true {
            let (datagrams, error) = await flow.readDatagrams()
            if let error {
                firstError.set(error)
                return
            }
            guard let datagrams, !datagrams.isEmpty else { return }
            for (payload, endpoint) in datagrams {
                guard let target = TargetAddress(endpoint: endpoint) else { continue }
                do {
                    try await assoc.send(payload, to: target)
                    tracker.addBytes(id, up: payload.count)
                } catch {
                    firstError.set(error)
                    return
                }
            }
        }
    }

    private func pumpRelayToApp(_ assoc: SOCKS5UDPAssociation) async {
        while true {
            do {
                let (from, payload) = try await assoc.receive()
                try await flow.writeDatagrams([(payload, from.nwEndpoint)])
                tracker.addBytes(id, down: payload.count)
            } catch {
                if !(error is ProxyError) { firstError.set(error) }
                // 单个畸形报文不终止会话
                if case ProxyError.protocolViolation = error { continue }
                if case ProxyError.unsupported = error { continue }
                return
            }
        }
    }
}
