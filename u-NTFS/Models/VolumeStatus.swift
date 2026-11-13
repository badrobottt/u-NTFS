import Foundation

/// Current mount state of an external NTFS partition.
nonisolated enum MountState: Equatable, Sendable {
    case unmounted
    case mountedReadOnly
    case mountedWritable
    case transitioning(String)
    case error(String)

    var title: String {
        switch self {
        case .unmounted:
            return "Unmounted"
        case .mountedReadOnly:
            return "Read-Only"
        case .mountedWritable:
            return "Read / Write"
        case .transitioning(let step):
            return step
        case .error:
            return "Attention Required"
        }
    }

    var isWritable: Bool {
        if case .mountedWritable = self { return true }
        return false
    }

    var isMounted: Bool {
        switch self {
        case .mountedReadOnly, .mountedWritable:
            return true
        case .unmounted, .transitioning, .error:
            return false
        }
    }
}

/// Stages of the mouNTFS 4-step transactional read/write mount pipeline.
nonisolated enum MountTransactionStep: Int, CaseIterable, Sendable {
    case validatingIdentity = 0
    case preparingDirectory = 1
    case unmountingReadOnly = 2
    case mountingNTFS3G = 3
    case verifyingWriteAccess = 4
    case recoveringReadOnly = 5

    var progressLabel: String {
        switch self {
        case .validatingIdentity:
            return "Validating partition & IOKit media identity…"
        case .preparingDirectory:
            return "[1/4] Preparing controlled mount directory…"
        case .unmountingReadOnly:
            return "[2/4] Unmounting existing read-only volume…"
        case .mountingNTFS3G:
            return "[3/4] Mounting with ntfs-3g driver…"
        case .verifyingWriteAccess:
            return "[4/4] Verifying user write access in Finder…"
        case .recoveringReadOnly:
            return "Restoring safe read-only mount via macOS…"
        }
    }
}

/// Data-safety and health warnings detected before or during NTFS operations.
nonisolated enum VolumeHealthWarning: Equatable, Hashable, Identifiable, Sendable {
    case hibernatedOrFastStartup
    case uncleanOrDirtyJournal
    case fullDiskAccessRequired(driverPath: String)
    case macFUSEApprovalRequired
    case missingMediaIdentity
    case lockContention
    case custom(String)

    var id: String {
        switch self {
        case .hibernatedOrFastStartup:
            return "hibernated"
        case .uncleanOrDirtyJournal:
            return "dirty"
        case .fullDiskAccessRequired(let path):
            return "fda:\(path)"
        case .macFUSEApprovalRequired:
            return "macfuse"
        case .missingMediaIdentity:
            return "identity"
        case .lockContention:
            return "lock"
        case .custom(let msg):
            return "custom:\(msg)"
        }
    }

    var title: String {
        switch self {
        case .hibernatedOrFastStartup:
            return "Windows Hibernation / Fast Startup Detected"
        case .uncleanOrDirtyJournal:
            return "Unclean NTFS Volume (Dirty Flag)"
        case .fullDiskAccessRequired:
            return "Full Disk Access Required for ntfs-3g"
        case .macFUSEApprovalRequired:
            return "macFUSE Driver Approval Needed"
        case .missingMediaIdentity:
            return "Hardware Identity Unavailable"
        case .lockContention:
            return "System Device Lock Active"
        case .custom:
            return "Volume Safety Notice"
        }
    }

    var explanation: String {
        switch self {
        case .hibernatedOrFastStartup:
            return "ntfs-3g reported an unsafe hibernated state. To prevent data corruption, u-NTFS refuses forced mounting. Boot Windows and perform a full shutdown or run chkdsk."
        case .uncleanOrDirtyJournal:
            return "The NTFS filesystem was not cleanly dismounted. Preserving read-only mode to protect user data; u-NTFS never clears dirty flags automatically."
        case .fullDiskAccessRequired(let driverPath):
            return "macOS denied raw device access to ntfs-3g (\(driverPath)). Grant Full Disk Access to the actual ntfs-3g executable in System Settings → Privacy & Security → Full Disk Access."
        case .macFUSEApprovalRequired:
            return "macFUSE could not load the filesystem backend. Approve the system extension in System Settings → Privacy & Security and restart if required."
        case .missingMediaIdentity:
            return "The physical IOMedia registry identity could not be pinned. Reconnect the drive and refresh before enabling write access."
        case .lockContention:
            return "Another operation or stale lock in /Library/mountfs-locks holds this device. Inspect running ntfs-3g processes before removing locks."
        case .custom(let message):
            return message
        }
    }
}
