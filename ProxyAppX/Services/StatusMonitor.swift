import Foundation
import Observation
import ProxyAppXCore

/// 每秒向扩展拉取一次状态，并在本地累积日志。
@MainActor
@Observable
final class StatusMonitor {
    private(set) var snapshot: StatusSnapshot?
    private(set) var logs: [LogEntry] = []
    private(set) var lastError: String?

    /// 每秒速率（字节）
    private(set) var upRate: Double = 0
    private(set) var downRate: Double = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previousTotals: (TrafficTotals, Date)?
    @ObservationIgnored private let controller: ProxyController
    private let logCapacity = 2000

    init(controller: ProxyController) {
        self.controller = controller
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clearLogs() async {
        logs.removeAll()
        _ = try? await controller.send(.clearLogs)
        await poll()
    }

    private func poll() async {
        guard controller.isRunning else {
            if snapshot != nil {
                snapshot = nil
                upRate = 0
                downRate = 0
                previousTotals = nil
            }
            return
        }
        do {
            let response = try await controller.send(.status(logsAfter: logs.last?.id))
            guard case let .status(s) = response else { return }
            // 扩展重启后日志 id 会从头开始
            if let first = s.logs.first, let last = logs.last, first.id <= last.id { logs.removeAll() }
            if let prev = snapshot, prev.startedAt != s.startedAt { logs.removeAll() }
            logs.append(contentsOf: s.logs)
            if logs.count > logCapacity { logs.removeFirst(logs.count - logCapacity) }

            let now = Date()
            if let (prevTotals, prevDate) = previousTotals, s.totals.bytesUp >= prevTotals.bytesUp,
               s.totals.bytesDown >= prevTotals.bytesDown {
                let dt = max(now.timeIntervalSince(prevDate), 0.001)
                upRate = Double(s.totals.bytesUp - prevTotals.bytesUp) / dt
                downRate = Double(s.totals.bytesDown - prevTotals.bytesDown) / dt
            }
            previousTotals = (s.totals, now)
            snapshot = s
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
