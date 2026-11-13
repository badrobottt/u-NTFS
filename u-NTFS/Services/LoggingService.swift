import Foundation
import OSLog
import Observation

/// Severity level for diagnostic log entries.
nonisolated enum DiagnosticLogLevel: String, CaseIterable, Codable, Sendable {
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARN"
    case error = "ERROR"
}

/// Structured log item displayed in the Diagnostics console.
nonisolated struct DiagnosticLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLogLevel
    let category: String
    let message: String
    let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    var formattedLine: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timeStr = formatter.string(from: timestamp)
        if let details, !details.isEmpty {
            return "[\(timeStr)] [\(level.rawValue)] [\(category)] \(message)\n\(details)"
        }
        return "[\(timeStr)] [\(level.rawValue)] [\(category)] \(message)"
    }
}

/// Centralized logging service backed by Apple's unified OSLog and an observable in-memory buffer.
@Observable
final class LoggingService {
    static let shared = LoggingService()

    private let osLogger = Logger(subsystem: "com.mountfs.ntfs.app", category: "Engine")
    private(set) var entries: [DiagnosticLogEntry] = []
    private(set) var lastOperationOutput: String?
    private(set) var lastScanReport: String = "No scan has completed yet."

    var verboseLoggingEnabled: Bool = true

    func log(
        _ message: String,
        level: DiagnosticLogLevel = .info,
        category: String = "Engine",
        details: String? = nil
    ) {
        let entry = DiagnosticLogEntry(
            level: level,
            category: category,
            message: message,
            details: details
        )
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries.removeLast(entries.count - 500)
        }

        switch level {
        case .info:
            osLogger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .notice:
            osLogger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            osLogger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error:
            osLogger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
    }

    func recordOperationOutput(_ output: String) {
        lastOperationOutput = output
    }

    func recordScanReport(_ report: String) {
        lastScanReport = report
    }

    func clearLogs() {
        entries.removeAll()
    }

    func exportFormattedReport() -> String {
        var sections: [String] = []
        sections.append("=== u-NTFS Diagnostic Report ===")
        sections.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        sections.append("")
        sections.append("--- Latest Disk Scan Report ---")
        sections.append(lastScanReport)
        if let lastOperationOutput, !lastOperationOutput.isEmpty {
            sections.append("")
            sections.append("--- Last Operation Output ---")
            sections.append(lastOperationOutput)
        }
        sections.append("")
        sections.append("--- Session Log Entries (\(entries.count)) ---")
        for entry in entries.reversed() {
            sections.append(entry.formattedLine)
        }
        return sections.joined(separator: "\n")
    }
}
