//
//  Log.swift
//  Agentic
//

import Foundation

/// One captured line. Held in memory for the log page and written to disk so
/// a session is still readable after the app is killed and reopened.
nonisolated struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let kind: Log.Kind
    let message: String
}

/// Console tracing for development. Every line carries a fixed-width kind tag
/// so a session reads as columns and one feature can be pulled out with grep:
///
///     [SCAN ] read 412 characters off the label
///     [TOOL ] searchBeanCorpus query="gayo" limit=3
///     [TOOL ] searchBeanCorpus matchesFound 3
///
/// Compiled out of release builds, so an instrumented interaction costs
/// nothing once shipped. The message is an autoclosure for the same reason:
/// building the string is skipped when the log is off.
nonisolated enum Log {
    enum Kind: String, Sendable, CaseIterable {
        case agent = "AGENT"
        case tool = "TOOL"
        case corpus = "CORPUS"
        case cupboard = "CUPBRD"
        case brew = "BREW"
        case scan = "SCAN"
        case quiz = "QUIZ"
        case store = "STORE"
        case ui = "UI"
        case failure = "FAIL"
    }

    static func write(_ kind: Kind, _ message: @autoclosure () -> String) {
        #if DEBUG
            let text = message()
            print("[\(kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))] \(text)")
            LogStore.shared.append(kind, text)
        #endif
    }
}

/// The log page's source of truth, holding the same lines the Xcode console
/// gets so a session can be read on the device it happened on.
///
/// Guarded by a lock rather than written as an actor: `Log.write` is called
/// from whatever context a tool happens to run on, and an actor would make
/// every one of those call sites await. Logging that suspends changes the
/// ordering of the thing it is measuring.
nonisolated final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    /// Enough for a long session. Older lines fall off the front, in memory
    /// and in the file, so neither grows without bound across launches.
    static let capacity = 1000

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var handle: FileHandle?
    private var loaded = false

    /// Documents rather than Caches: the point of keeping a file at all is
    /// that yesterday's session is still there, and the system empties Caches
    /// whenever it wants the space back.
    static var fileURL: URL? {
        let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return documents?.appending(path: "agentic.log")
    }

    func append(_ kind: Log.Kind, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        let entry = LogEntry(id: UUID(), date: Date(), kind: kind, message: message)
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }

        if let handle, let data = (Self.line(entry) + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    /// A value copy, so the view is never reading the array while a tool on
    /// another thread is appending to it.
    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries = []
        try? handle?.close()
        handle = nil
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
        // Left marked loaded so the next append does not read the file we
        // just deleted back off disk.
        loaded = true
    }

    /// Deferred to the first read or write rather than done in `init`, because
    /// the singleton is built the first time anything logs, which is during
    /// app startup.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL else { return }

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            entries = text.split(separator: "\n").suffix(Self.capacity).compactMap(Self.parse)
            // Rewritten at the cap, which is the only place the file is
            // trimmed. Appending is otherwise the only write it ever takes.
            let kept = entries.map(Self.line).joined(separator: "\n")
            try? (kept.isEmpty ? "" : kept + "\n").write(to: url, atomically: true, encoding: .utf8)
        } else {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Seconds since the epoch rather than a formatted date, so reading the
    /// file back needs no date parser and no shared formatter to lock around.
    static func line(_ entry: LogEntry) -> String {
        // A line break would break one-entry-per-line, and a log line that
        // wraps is not worth the parser it would take to restore.
        let flat = entry.message.replacingOccurrences(of: "\n", with: " ")
        return "\(entry.date.timeIntervalSince1970)\t\(entry.kind.rawValue)\t\(flat)"
    }

    static func parse(_ line: Substring) -> LogEntry? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
            let seconds = TimeInterval(parts[0]),
            let kind = Log.Kind(rawValue: String(parts[1]))
        else { return nil }
        return LogEntry(
            id: UUID(), date: Date(timeIntervalSince1970: seconds), kind: kind, message: String(parts[2])
        )
    }
}
