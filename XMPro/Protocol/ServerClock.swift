// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

final class ServerClock: @unchecked Sendable {
    static let shared = ServerClock()

    private let lock = NSLock()
    private var offsetMs: Int64 = 0
    private let wallNow: @Sendable () -> Date
    private static let maxDriftMs: Int64 = 24 * 60 * 60 * 1000

    /// An injected source must itself be safe for concurrent use.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        wallNow = now
    }

    var synced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offsetMs != 0
    }

    func now() -> Int64 {
        guard let local = localMillis() else {
            // The injected clock is unusable (non-finite or out of
            // Int64 range); return the last learned offset instead of
            // trapping. Callers get a wrong-but-defined time, never a crash.
            lock.lock()
            defer { lock.unlock() }
            return offsetMs
        }
        lock.lock()
        let offset = offsetMs
        lock.unlock()
        let sum = local.addingReportingOverflow(offset)
        if sum.overflow {
            return offset >= 0 ? .max : .min
        }
        return sum.partialValue
    }

    func observeMillis(_ raw: Int64) {
        guard raw > 0 else {
            return
        }
        let millis = raw < 100_000_000_000 ? raw * 1000 : raw
        guard let local = localMillis() else {
            return
        }
        let subtraction = millis.subtractingReportingOverflow(local)
        guard !subtraction.overflow else {
            return
        }
        let drift = subtraction.partialValue
        guard drift >= -Self.maxDriftMs, drift <= Self.maxDriftMs else {
            return
        }
        guard drift <= -1000 || drift >= 1000 else {
            return
        }

        lock.lock()
        offsetMs = drift
        lock.unlock()
    }

    func observePayload(timestamp: Any?) {
        if let string = timestamp as? String,
           let value = Int64(string) {
            observeMillis(value)
        } else if let number = timestamp as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite, value > 0,
                  value < Double(Int64.max) else {
                return
            }
            observeMillis(Int64(value))
        }
    }

    func observeDateHeader(_ value: String?) {
        guard let value, let date = Self.parseHTTPDate(value) else {
            return
        }
        let millis = date.timeIntervalSince1970 * 1000
        guard millis.isFinite, millis > 0,
              millis < Double(Int64.max) else {
            return
        }
        observeMillis(Int64(millis))
    }

    static func parseHTTPDate(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        // Local formatter avoids sharing DateFormatter's mutable state.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        return formatter.date(from: text)
    }

    private func localMillis() -> Int64? {
        let seconds = wallNow().timeIntervalSince1970
        guard seconds.isFinite else {
            return nil
        }
        let millis = seconds * 1000
        guard millis >= Double(Int64.min), millis < Double(Int64.max) else {
            return nil
        }
        return Int64(millis)
    }
}
