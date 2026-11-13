import Foundation
import Darwin

/// Domain errors for NTFS filesystem inspection, mounting, verification, and recovery.
nonisolated enum NTFSFilesystemError: LocalizedError, Equatable, Sendable {
    case invalidDeviceIdentifier(String)
    case internalOrWholeDiskRejected(String)
    case nonNTFSVolume(String)
    case missingMediaIdentity(String)
    case mediaDisconnectedOrReplaced(String)
    case driverNotInstalled(String)
    case backendUnavailable(String)
    case deviceLocked(String)
    case authorizationCancelled
    case hibernatedOrUnsafeVolume(String)
    case fullDiskAccessDenied(driverPath: String, details: String)
    case macFUSEKernelUnavailable(String)
    case mountFailedWithRecovery(reason: String, recoveredReadOnly: Bool)
    case writeVerificationFailed(reason: String, recoveredReadOnly: Bool)
    case operationUncertain(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceIdentifier(let dev):
            return "Invalid partition identifier '\(dev)'. Expected an external partition like disk4s1."
        case .internalOrWholeDiskRejected(let reason):
            return "Refused for safety: \(reason)."
        case .nonNTFSVolume(let fs):
            return "Volume is not an NTFS partition (detected: \(fs))."
        case .missingMediaIdentity(let dev):
            return "Could not establish physical IOKit media identity for \(dev)."
        case .mediaDisconnectedOrReplaced(let dev):
            return "The drive \(dev) disconnected or was replaced before the operation completed. Aborted for safety."
        case .driverNotInstalled(let msg):
            return msg
        case .backendUnavailable(let msg):
            return msg
        case .deviceLocked(let msg):
            return msg
        case .authorizationCancelled:
            return "Administrator authorization was cancelled."
        case .hibernatedOrUnsafeVolume(let details):
            return "NTFS volume is hibernated or unclean (Windows Fast Startup). Refusing forced write mount to prevent data corruption.\n\(details)"
        case .fullDiskAccessDenied(let driverPath, let details):
            return "macOS denied device access to \(driverPath). Grant Full Disk Access to the ntfs-3g executable in System Settings → Privacy & Security → Full Disk Access.\n\(details)"
        case .macFUSEKernelUnavailable(let details):
            return "macFUSE could not load the filesystem backend. Approve the system extension in System Settings → Privacy & Security.\n\(details)"
        case .mountFailedWithRecovery(let reason, let recovered):
            let recoveryNote = recovered
                ? "The volume was automatically restored to safe read-only mode."
                : "Automatic read-only recovery could not be confirmed; check Disk Utility."
            return "Failed to mount NTFS volume in read/write mode: \(reason)\n\(recoveryNote)"
        case .writeVerificationFailed(let reason, let recovered):
            let recoveryNote = recovered
                ? "The volume was automatically restored to safe read-only mode."
                : "Automatic read-only recovery could not be confirmed."
            return "Write verification failed: \(reason)\n\(recoveryNote)"
        case .operationUncertain(let details):
            return "Mount completion and device-lock state are uncertain (status 125). Inspect diagnostic logs before retrying.\n\(details)"
        case .commandFailed(let details):
            return details
        }
    }
}

/// Inspects `ntfs-3g` and `macFUSE` / `FSKit` / `FUSE-T` installation and parses driver diagnostics
/// using the exact rules from `guoquan/mountfs` (`mountfs.sh`).
nonisolated enum NTFSBackendAdapter {

    static let candidateDriverPaths = [
        "/opt/homebrew/bin/ntfs-3g",
        "/usr/local/bin/ntfs-3g"
    ]

    static let macFUSEBundlePath = "/Library/Filesystems/macfuse.fs"
    static let fuseTBundlePath = "/Library/Filesystems/fuse-t.fs"

    /// Locates the installed Homebrew `ntfs-3g` binary (`find_driver` in `mountfs.sh`).
    static func findDriver(fileManager: FileManager = .default) -> String? {
        candidateDriverPaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Checks whether the current macOS version is at least 15.4 (`macos_at_least 15 4` in `mountfs.sh`).
    static func isFSKitSupportedOnCurrentOS() -> Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 15 { return true }
        if v.majorVersion == 15 && v.minorVersion >= 4 { return true }
        return false
    }

    /// Builds the `ntfs-3g` mount options string matching `mountfs.sh` (`build_mount_options`):
    /// `rw,norecover,allow_other,default_permissions,uid=<uid>,gid=<gid>,umask=077,(local|backend=fskit)`
    static func buildMountOptions(
        backend: FilesystemBackendType,
        uid: uid_t = getuid(),
        gid: gid_t = getgid(),
        volumeLabel: String? = nil
    ) -> String {
        var options = [
            "rw",
            "norecover",
            "allow_other",
            "default_permissions",
            "uid=\(uid)",
            "gid=\(gid)",
            "umask=077",
            backend.mountOptionFlag
        ]
        if let label = volumeLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: ""),
           !label.isEmpty,
           label.range(of: "^[A-Za-z0-9 _.-]{1,64}$", options: .regularExpression) != nil {
            options.append("volname=\(label)")
        }
        return options.joined(separator: ",")
    }

    /// Inspects `ntfs-3g` output (`report_driver_failure` in `mountfs.sh`) to classify failure causes
    /// and surface corresponding `VolumeHealthWarning` items.
    static func classifyDriverFailure(
        logText: String,
        driverPath: String,
        backend: FilesystemBackendType
    ) -> (error: NTFSFilesystemError, warnings: [VolumeHealthWarning]) {
        let lower = logText.lowercased()

        if logText.contains("Operation not permitted") || logText.contains("Permission denied") {
            let warning = VolumeHealthWarning.fullDiskAccessRequired(driverPath: driverPath)
            return (.fullDiskAccessDenied(driverPath: driverPath, details: logText), [warning])
        }

        if logText.contains("Unsupported macOS Version") || logText.contains("the file system is not available") {
            let warning = VolumeHealthWarning.macFUSEApprovalRequired
            return (.macFUSEKernelUnavailable(logText), [warning])
        }

        if lower.contains("hibernated") || lower.contains("fast restart") || lower.contains("unsafe state") {
            let warning = VolumeHealthWarning.hibernatedOrFastStartup
            return (.hibernatedOrUnsafeVolume(logText), [warning])
        }

        if lower.contains("unclean") || lower.contains("dirty") || lower.contains("chkdsk") {
            let warning = VolumeHealthWarning.uncleanOrDirtyJournal
            return (.hibernatedOrUnsafeVolume(logText), [warning])
        }

        var message = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = "ntfs-3g exited with an error for backend '\(backend.rawValue)'."
        }
        return (.mountFailedWithRecovery(reason: message, recoveredReadOnly: false), [])
    }

    /// Performs a non-destructive user-level write verification probe on a mounted volume
    /// (`verify_write` in `mountfs.sh`: creates `.mountfs-write-test.XXXXXXXX`, writes verification bytes, and removes it).
    static func verifyUserWriteAccess(atMountPoint mountPoint: String) -> Result<Void, Error> {
        let templatePath = (mountPoint as NSString).appendingPathComponent(".mountfs-write-test.XXXXXXXX")
        var templateBytes = Array(templatePath.utf8CString)
        let fd = templateBytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return mkstemp(base)
        }
        guard fd >= 0 else {
            let code = errno
            let msg = String(cString: strerror(code))
            return .failure(NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Cannot create temporary write-test file at \(mountPoint): \(msg)"]
            ))
        }

        let createdPath = templateBytes.withUnsafeBufferPointer { buf -> String in
            String(cString: buf.baseAddress!)
        }

        defer {
            close(fd)
            unlink(createdPath)
        }

        let payload = Data("u-NTFS write verification\n".utf8)
        let written = payload.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return write(fd, base, rawBuf.count)
        }

        guard written == payload.count, fsync(fd) == 0 else {
            let code = errno
            let msg = String(cString: strerror(code))
            return .failure(NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Failed to write verification payload to \(createdPath): \(msg)"]
            ))
        }

        return .success(())
    }
}
