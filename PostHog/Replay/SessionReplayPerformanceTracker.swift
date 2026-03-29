#if os(iOS)
    import Foundation
    import QuartzCore
    import os.log
    import os.signpost

    extension Notification.Name {
        static let postHogSessionReplayPerformanceReport = Notification.Name("PostHogSessionReplayPerformanceReport")
    }

    final class SessionReplayPerformanceTracker {
        static let shared = SessionReplayPerformanceTracker()

        private let signpostLog = OSLog(subsystem: "com.posthog.sessionreplay", category: .pointsOfInterest)
        private let statsLock = NSLock()
        private var stats: [String: [Double]] = [:]
        private var snapshotCount = 0
        private var pendingReportCount: Int?
        private let reportInterval = 30

        struct Span {
            fileprivate let signpostID: OSSignpostID
            fileprivate let name: StaticString
            fileprivate let startTime: CFTimeInterval
        }

        func begin(_ name: StaticString) -> Span {
            let id = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: name, signpostID: id)
            return Span(signpostID: id, name: name, startTime: CACurrentMediaTime())
        }

        func end(_ span: Span, phase: String) {
            let durationMs = (CACurrentMediaTime() - span.startTime) * 1000
            os_signpost(.end, log: signpostLog, name: span.name, signpostID: span.signpostID)

            statsLock.lock()
            stats[phase, default: []].append(durationMs)

            if phase == "total_main_thread" {
                snapshotCount += 1
                if snapshotCount > 0 && snapshotCount % reportInterval == 0 {
                    pendingReportCount = snapshotCount
                }
            }

            let shouldReport = phase == "total_background" && pendingReportCount != nil
            let currentStats = shouldReport ? stats : nil
            let currentCount = pendingReportCount
            if shouldReport {
                pendingReportCount = nil
                stats.removeAll(keepingCapacity: true)
            }
            statsLock.unlock()

            if let snapshot = currentStats, let count = currentCount {
                printReport(snapshot, count: count)
            }
        }

        private func printReport(_ stats: [String: [Double]], count: Int) {
            var report = "\n╔══════════════════════════════════════════════════════════════╗\n"
            report += "║  SESSION REPLAY PERFORMANCE — snapshot #\(count)".padding(toLength: 63, withPad: " ", startingAt: 0) + "║\n"
            report += "╠══════════════════════════════════════════════════════════════╣\n"
            report += "║  Phase                        avg      p50      p95     max ║\n"
            report += "╠══════════════════════════════════════════════════════════════╣\n"

            let order = [
                "find_maskable_widgets",
                "draw_hierarchy",
                "total_main_thread",
                "mask_image",
                "base64_encode",
                "wireframe_to_dict",
                "total_background",
            ]

            for phase in order {
                guard let values = stats[phase], !values.isEmpty else { continue }
                let sorted = values.sorted()
                let avg = sorted.reduce(0, +) / Double(sorted.count)
                let p50 = percentile(sorted, 0.50)
                let p95 = percentile(sorted, 0.95)
                let max = sorted.last ?? 0

                let label = phase.padding(toLength: 26, withPad: " ", startingAt: 0)
                report += String(format: "║  %@ %6.1fms  %6.1fms  %6.1fms %6.1fms ║\n", label, avg, p50, p95, max)
            }

            report += "╠══════════════════════════════════════════════════════════════╣\n"
            let sampleCount = stats["total_main_thread"]?.count ?? 0
            report += "║  Samples: \(sampleCount)".padding(toLength: 63, withPad: " ", startingAt: 0) + "║\n"
            report += "╚══════════════════════════════════════════════════════════════╝"

            NSLog("[PostHog] %@", report)
        }

        private func percentile(_ sorted: [Double], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = p * Double(sorted.count - 1)
            let lower = Int(floor(index))
            let upper = min(lower + 1, sorted.count - 1)
            let fraction = index - Double(lower)
            return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
        }
    }
#endif
