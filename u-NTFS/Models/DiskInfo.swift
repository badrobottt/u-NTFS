import Foundation

/// Core diskutil + kernel mount-table metadata model adapted directly from guoquan/mountfs (`Sources/MountFSCore/DiskMetadata.swift`).
/// Unknown safety flags are deliberately not interpreted as external partitions.
nonisolated public struct DiskMetadata: Equatable, Sendable {
    public let device: String
    public let name: String
    public let filesystem: String?
    public let reportedFilesystem: String?
    public let isInternal: Bool?
    public let isWholeDisk: Bool?
    public let mountPoint: String?
    public let readOnly: Bool

    public init(_ info: [String: Any], mountState: [String: Any]? = nil, verifiedNTFS: Bool = false) {
        device = info["DeviceIdentifier"] as? String ?? "unknown"
        let rawName = (info["VolumeName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (rawName?.isEmpty == false) ? rawName! : device
        let reported = info["FilesystemType"] as? String
        reportedFilesystem = reported
        let fuseTypes = ["macfuse", "fusefs", "osxfuse", "ntfs-3g", "fuse-t"]
        filesystem = verifiedNTFS && (reported == nil || fuseTypes.contains(reported!))
            ? "ntfs" : reported
        isInternal = info["Internal"] as? Bool
        isWholeDisk = info["WholeDisk"] as? Bool
        let state = mountState ?? info
        let point = state["MountPoint"] as? String ?? ""
        mountPoint = point.isEmpty ? nil : point
        readOnly = !(state["WritableVolume"] as? Bool ?? false)
    }

    public var isMounted: Bool { mountPoint != nil }

    public var isExternalPartition: Bool {
        guard isInternal == false && isWholeDisk == false else { return false }
        guard let fs = filesystem, !fs.isEmpty else { return false }
        return true
    }

    public var isExternalNTFSPartition: Bool {
        filesystem == "ntfs" && isInternal == false && isWholeDisk == false
    }

    public var exclusionReason: String {
        if isInternal == true { return "internal disk" }
        if isInternal == nil { return "missing Internal flag" }
        if isWholeDisk == true { return "whole disk (partition required)" }
        if isWholeDisk == nil { return "missing WholeDisk flag" }
        if filesystem != "ntfs" { return "filesystem: \(filesystem ?? "unrecognized")" }
        return "included"
    }
}

/// Rich model representing a detected external NTFS partition in the UI and services.
nonisolated struct DiskInfo: Identifiable, Equatable, Hashable, Sendable {
    let deviceIdentifier: String          // e.g. "disk4s1"
    let parentWholeDisk: String           // e.g. "disk4"
    let mediaIdentity: String?            // e.g. "iomedia:4294969123:4294969100:1000204886016"
    let volumeUUID: String?               // VolumeUUID from diskutil
    let partitionUUID: String?            // DiskUUID (GPT partition UUID)
    let name: String                      // Volume label or fallback BSD name
    let filesystemName: String            // "NTFS" or "NTFS (macFUSE / ntfs-3g)"
    let rawFilesystemType: String         // "ntfs", "macfuse", etc.
    let isNTFS: Bool                      // true if NTFS partition, false for exFAT/APFS/FAT32/etc.
    let totalCapacityBytes: Int64
    let availableCapacityBytes: Int64
    let connectionType: String            // e.g. "USB", "Thunderbolt", "External"
    let deviceModel: String               // e.g. "Samsung PSSD T7"
    let mountPoint: String?               // e.g. "/Volumes/MyDrive" or "/Volumes/mountfs.disk4s1.XXXX"
    let isReadOnly: Bool
    let isInternal: Bool
    let isWholeDisk: Bool
    let smartStatus: String?
    let activeBackendDescription: String
    var healthWarnings: [VolumeHealthWarning]

    var id: String { deviceIdentifier }

    var isMounted: Bool {
        mountPoint != nil
    }

    var isWritable: Bool {
        isMounted && !isReadOnly
    }

    var usedCapacityBytes: Int64 {
        max(0, totalCapacityBytes - availableCapacityBytes)
    }

    var usageFraction: Double {
        guard totalCapacityBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedCapacityBytes) / Double(totalCapacityBytes)))
    }

    var mountState: MountState {
        guard isMounted else { return .unmounted }
        return isReadOnly ? .mountedReadOnly : .mountedWritable
    }

    var formattedTotalCapacity: String {
        ByteCountFormatter.string(fromByteCount: totalCapacityBytes, countStyle: .file)
    }

    var formattedUsedCapacity: String {
        ByteCountFormatter.string(fromByteCount: usedCapacityBytes, countStyle: .file)
    }

    var formattedAvailableCapacity: String {
        ByteCountFormatter.string(fromByteCount: availableCapacityBytes, countStyle: .file)
    }
}
