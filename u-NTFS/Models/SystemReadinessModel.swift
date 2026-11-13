import Foundation
import SwiftUI

/// Readiness status for a single system requirement or permission.
enum ReadinessStatus: Equatable, Sendable {
    case ready
    case warning(String)
    case blocked(String)
    case notInstalled(String)
    case optional(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var badgeColor: Color {
        switch self {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .blocked:
            return .red
        case .notInstalled:
            return .red
        case .optional:
            return .blue
        }
    }

    var iconName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        case .notInstalled:
            return "arrow.down.circle.fill"
        case .optional:
            return "info.circle.fill"
        }
    }

    var statusTitle: String {
        switch self {
        case .ready:
            return "Ready & Authorized"
        case .warning:
            return "Attention Needed"
        case .blocked:
            return "Action Required"
        case .notInstalled:
            return "Not Installed"
        case .optional:
            return "Optional"
        }
    }
}

/// Category grouping for checklist items.
enum ReadinessCategory: String, CaseIterable, Identifiable, Sendable {
    case drivers = "Filesystem Drivers & Binaries"
    case permissions = "macOS Security & Permissions"
    case hardware = "Drive Access & Operations"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .drivers:
            return "externaldrive.badge.timemachine"
        case .permissions:
            return "lock.shield.fill"
        case .hardware:
            return "internaldrive"
        }
    }
}

/// Represents a single checklist item in the readiness inspection.
struct ReadinessCheckItem: Identifiable, Sendable {
    let id: String
    let category: ReadinessCategory
    let title: String
    let subtitle: String
    let status: ReadinessStatus
    let detailedInstruction: String
    let actionTitle: String?
    let actionType: ReadinessActionType?

    init(
        id: String,
        category: ReadinessCategory,
        title: String,
        subtitle: String,
        status: ReadinessStatus,
        detailedInstruction: String,
        actionTitle: String? = nil,
        actionType: ReadinessActionType? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.detailedInstruction = detailedInstruction
        self.actionTitle = actionTitle
        self.actionType = actionType
    }
}

/// Action types triggered by the user from the readiness inspector.
enum ReadinessActionType: Sendable {
    case openPrivacySecurity
    case openFullDiskAccess
    case installDrivers
    case installFuseT
    case switchToFuseT
    case refresh
}
