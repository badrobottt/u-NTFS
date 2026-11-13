import Foundation
import Darwin

/// Output of a non-destructive read-only disk scan.
nonisolated struct DiskScanResult: Equatable, Sendable {
    let disks: [DiskInfo]
    let report: String
}

/// Protocol for discovering and inspecting external NTFS volumes.
protocol VolumeInformationServicing: Sendable {
    nonisolated func scanExternalNTFSVolumes(verifiedIdentities: [String: String], includeNonNTFS: Bool) -> DiskScanResult?
    nonisolated func inspectSingleDisk(device: String, verifiedIdentities: [String: String]) -> DiskInfo?
    nonisolated func rawDiskutilInfo(for device: String) -> [String: Any]?
}

extension VolumeInformationServicing {
    nonisolated func scanExternalNTFSVolumes(verifiedIdentities: [String: String]) -> DiskScanResult? {
        scanExternalNTFSVolumes(verifiedIdentities: verifiedIdentities, includeNonNTFS: false)
    }
}

/// Concrete implementation of `VolumeInformationServicing` combining `guoquan/mountfs` (`scanVolumes`,
/// `DiskMetadata`, `mediaIdentity`, and kernel `mountState`) with rich storage capacity & health metadata.
final class VolumeInformationService: VolumeInformationServicing, @unchecked Sendable {

    nonisolated init() {}

    nonisolated func rawDiskutilInfo(for device: String) -> [String: Any]? {
        diskDictionary(["info", "-plist", device])
    }

    nonisolated private func diskDictionary(_ arguments: [String]) -> [String: Any]? {
        let result = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", arguments, mergeErrors: false, timeout: 15)
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// Scans all attached disks using `diskutil list -plist`, `diskutil info -plist`,
    /// IOKit `IOMedia` registry identity, and Darwin kernel `getmntinfo` mount state.
    nonisolated func scanExternalNTFSVolumes(
        verifiedIdentities: [String: String] = [:],
        includeNonNTFS: Bool = false
    ) -> DiskScanResult? {
        guard let list = diskDictionary(["list", "-plist"]),
              let allDisks = list["AllDisks"] as? [String] else {
            return nil
        }

        var report = [
            "u-NTFS — read-only disk scan",
            "Scanned \(allDisks.count) disk identifiers (includeNonNTFS=\(includeNonNTFS))."
        ]

        var discovered: [DiskInfo] = []

        for device in allDisks {
            let scannedIdentity = MountFSEngine.mediaIdentity(device)
            guard let info = diskDictionary(["info", "-plist", device]) else {
                report.append("\(device): cannot read or parse diskutil info")
                continue
            }

            let externalPartition = (info["Internal"] as? Bool == false) && (info["WholeDisk"] as? Bool == false)
            let isVerifiedNTFS = externalPartition
                && verifiedIdentities[device] != nil
                && MountFSEngine.mediaIdentity(device) == verifiedIdentities[device]

            let reportedFS = (info["FilesystemType"] as? String)?.lowercased()
            let reportedName = (info["FilesystemName"] as? String)?.lowercased() ?? ""
            let contentHint = (info["Content"] as? String)?.lowercased() ?? ""
            let looksLikeNTFS = reportedFS == "ntfs"
                || reportedName.contains("ntfs")
                || isVerifiedNTFS

            // Skip system/EFI/container utility partitions when showing non-NTFS external drives
            let isSystemUtilityPartition = contentHint == "efi"
                || contentHint.contains("apple_apfs_isc")
                || contentHint.contains("apple_apfs_recovery")
                || reportedFS == "apfs_isc"

            let shouldInspectKernelMount = externalPartition && (looksLikeNTFS || (includeNonNTFS && !isSystemUtilityPartition))
            let state: [String: Any]? = shouldInspectKernelMount
                ? MountFSEngine.mountState(device)
                : nil

            if externalPartition && looksLikeNTFS && state == nil {
                report.append("\(device): kernel mount state unavailable; partition excluded")
                continue
            }

            // Normalize FilesystemType if diskutil reports Windows_NTFS / Microsoft Basic Data with NTFS name
            var normalizedInfo = info
            if reportedFS == nil && reportedName.contains("ntfs") {
                normalizedInfo["FilesystemType"] = "ntfs"
            }

            let metadata = DiskMetadata(normalizedInfo, mountState: state, verifiedNTFS: isVerifiedNTFS)
            let hasPartitionUUID = (info["DiskUUID"] as? String).map { !$0.isEmpty } ?? false
            let hasVolumeUUID = (info["VolumeUUID"] as? String).map { !$0.isEmpty } ?? false

            report.append(
                "\(device): \(metadata.exclusionReason); mounted=\(metadata.isMounted); readOnly=\(metadata.readOnly); DiskUUID=\(hasPartitionUUID ? "present" : "missing"); VolumeUUID=\(hasVolumeUUID ? "present" : "missing")"
            )

            let shouldInclude = metadata.isExternalNTFSPartition
                || (includeNonNTFS && metadata.isExternalPartition && !isSystemUtilityPartition)
            guard shouldInclude else { continue }

            let stableIdentity = (scannedIdentity != nil && MountFSEngine.mediaIdentity(device) == scannedIdentity)
                ? scannedIdentity
                : nil

            let diskInfo = buildDiskInfo(
                device: device,
                info: normalizedInfo,
                metadata: metadata,
                kernelMountState: state,
                mediaIdentity: stableIdentity
            )
            discovered.append(diskInfo)
        }

        report.append("Included \(discovered.count) external partition(s).")
        return DiskScanResult(disks: discovered, report: report.joined(separator: "\n"))
    }

    nonisolated func inspectSingleDisk(device: String, verifiedIdentities: [String: String] = [:]) -> DiskInfo? {
        guard MountFSEngine.isValidPartitionIdentifier(device),
              let info = diskDictionary(["info", "-plist", device]) else {
            return nil
        }
        let scannedIdentity = MountFSEngine.mediaIdentity(device)
        let isVerifiedNTFS = verifiedIdentities[device] != nil && scannedIdentity == verifiedIdentities[device]
        let state = MountFSEngine.mountState(device)
        let metadata = DiskMetadata(info, mountState: state, verifiedNTFS: isVerifiedNTFS)
        guard metadata.isExternalPartition else { return nil }
        return buildDiskInfo(
            device: device,
            info: info,
            metadata: metadata,
            kernelMountState: state,
            mediaIdentity: scannedIdentity
        )
    }

    nonisolated private func buildDiskInfo(
        device: String,
        info: [String: Any],
        metadata: DiskMetadata,
        kernelMountState: [String: Any]?,
        mediaIdentity: String?
    ) -> DiskInfo {
        let parentDisk = (info["ParentWholeDisk"] as? String) ?? device
        let volumeUUID = info["VolumeUUID"] as? String
        let partitionUUID = info["DiskUUID"] as? String
        let connectionType = (info["BusProtocol"] as? String) ?? "External"
        let deviceModel = (info["MediaName"] as? String)
            ?? (info["IORegistryEntryName"] as? String)
            ?? "External NTFS Drive"
        let smartStatus = info["SMARTStatus"] as? String

        var totalBytes = (info["TotalSize"] as? NSNumber)?.int64Value
            ?? (info["Size"] as? NSNumber)?.int64Value
            ?? 0
        var freeBytes = (info["FreeSpace"] as? NSNumber)?.int64Value
            ?? (info["VolumeFreeSpace"] as? NSNumber)?.int64Value
            ?? 0

        // When mounted via ntfs-3g / macFUSE or macOS NTFS, statfs on the mountPoint gives exact live capacity
        if let mountPoint = metadata.mountPoint, !mountPoint.isEmpty {
            var sfs = statfs()
            if statfs(mountPoint, &sfs) == 0 {
                let blockSize = Int64(sfs.f_bsize)
                let totalFromStatfs = Int64(sfs.f_blocks) * blockSize
                let freeFromStatfs = Int64(sfs.f_bavail) * blockSize
                if totalFromStatfs > 0 {
                    totalBytes = totalFromStatfs
                    freeBytes = max(0, min(totalFromStatfs, freeFromStatfs))
                }
            }
        }

        let isNTFS = (metadata.filesystem == "ntfs")
            || (metadata.reportedFilesystem?.lowercased() == "ntfs")
            || ((info["FilesystemName"] as? String)?.lowercased().contains("ntfs") == true)

        let kernelFSType = (kernelMountState?["FilesystemType"] as? String) ?? (metadata.reportedFilesystem ?? (isNTFS ? "ntfs" : "unknown"))
        let filesystemName: String
        let activeBackendDescription: String

        if isNTFS {
            filesystemName = metadata.readOnly ? "Windows NT File System (NTFS)" : "NTFS (Read/Write via ntfs-3g)"
            if !metadata.isMounted {
                activeBackendDescription = "Not Mounted"
            } else if metadata.readOnly {
                activeBackendDescription = "macOS Built-in NTFS (Read-Only)"
            } else if kernelFSType.contains("macfuse") || kernelFSType.contains("fuse") {
                activeBackendDescription = "macFUSE + ntfs-3g (Read/Write)"
            } else if kernelFSType.contains("fskit") {
                activeBackendDescription = "Apple FSKit + ntfs-3g (Read/Write)"
            } else {
                activeBackendDescription = "ntfs-3g (\(kernelFSType) Read/Write)"
            }
        } else {
            let userFacingFS = (info["FilesystemName"] as? String)
                ?? (info["FilesystemType"] as? String)?.uppercased()
                ?? "Non-NTFS"
            filesystemName = userFacingFS
            activeBackendDescription = metadata.isMounted
                ? "\(userFacingFS) (\(metadata.readOnly ? "Read-Only" : "Read/Write Native"))"
                : "Not Mounted"
        }

        // Clean display name if mounted under /Volumes/mountfs.diskNsM.XXXXXX
        var displayName = metadata.name
        if displayName.isEmpty || displayName == device {
            if let mp = metadata.mountPoint {
                let lastComponent = (mp as NSString).lastPathComponent
                if !lastComponent.hasPrefix("mountfs.\(device).") {
                    displayName = lastComponent
                }
            }
        }

        var warnings: [VolumeHealthWarning] = []
        if mediaIdentity == nil {
            warnings.append(.missingMediaIdentity)
        }
        if let smart = smartStatus, !smart.isEmpty, smart.lowercased() != "verified", smart.lowercased() != "not supported" {
            warnings.append(.custom("SMART Status: \(smart)"))
        }

        return DiskInfo(
            deviceIdentifier: device,
            parentWholeDisk: parentDisk.isEmpty ? device : parentDisk,
            mediaIdentity: mediaIdentity,
            volumeUUID: volumeUUID,
            partitionUUID: partitionUUID,
            name: displayName,
            filesystemName: filesystemName,
            rawFilesystemType: kernelFSType,
            isNTFS: isNTFS,
            totalCapacityBytes: totalBytes,
            availableCapacityBytes: freeBytes,
            connectionType: connectionType,
            deviceModel: deviceModel,
            mountPoint: metadata.mountPoint,
            isReadOnly: metadata.readOnly,
            isInternal: metadata.isInternal ?? false,
            isWholeDisk: metadata.isWholeDisk ?? false,
            smartStatus: smartStatus,
            activeBackendDescription: activeBackendDescription,
            healthWarnings: warnings
        )
    }
}
