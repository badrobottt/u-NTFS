import Foundation
import Darwin

/// Outcome of a read/write mount transaction.
nonisolated struct MountOperationOutcome: Equatable, Sendable {
    let device: String
    let mountPoint: String
    let mediaIdentity: String
    let backend: FilesystemBackendType
    let operationLog: String
    let warnings: [VolumeHealthWarning]
}

/// Protocol for mounting, unmounting, recovering, and ejecting external NTFS volumes.
protocol MountServicing: Sendable {
    nonisolated func enableReadWrite(
        for disk: DiskInfo,
        backend: FilesystemBackendType,
        onStepChange: @Sendable (MountTransactionStep) -> Void
    ) throws -> MountOperationOutcome

    nonisolated func remountReadOnly(for disk: DiskInfo) throws -> String
    nonisolated func unmountVolume(for disk: DiskInfo) throws -> String
    nonisolated func safelyEject(for disk: DiskInfo) throws -> String
}

/// Core NTFS Mounting & Recovery Engine ported directly from `guoquan/mountfs` (`mountfs.sh`, `RootBoundary.swift`, `MediaIdentity.swift`).
///
/// Guarantees:
/// 1. Validates partition format (`^disk[0-9]+s[0-9]+(s[0-9]+)?$`), external status (`Internal == false`), and partition status (`WholeDisk == false`).
/// 2. Pins physical IOKit `IOMedia` registry identity (`iomedia:<partitionID>:<parentID>:<size>`) before and after every transaction step.
/// 3. Never uses `remove_hiberfile` or force flags; mounts with `rw,norecover,allow_other,default_permissions,uid=<uid>,gid=<gid>,umask=077,(local|backend=fskit)`.
/// 4. Performs automatic read-only recovery (`/usr/sbin/diskutil mount readOnly <device>`) if `ntfs-3g` or write verification fails.
/// 5. Confirms kernel mount state via `getmntinfo(MNT_NOWAIT)` and verifies user-level write access with a non-destructive `.mountfs-write-test.XXXXXXXX` probe.
final class MountService: MountServicing, @unchecked Sendable {
    nonisolated private let volumeService: VolumeInformationServicing
    nonisolated private let backendService: NTFSBackendServicing
    nonisolated private let authService: AuthorizationServicing

    nonisolated init(
        volumeService: VolumeInformationServicing,
        backendService: NTFSBackendServicing,
        authService: AuthorizationServicing
    ) {
        self.volumeService = volumeService
        self.backendService = backendService
        self.authService = authService
    }

    /// Transactional shell script executed with administrator privileges in a single prompt,
    /// mirroring `mount_volume` and `recover_volume` in `guoquan/mountfs/mountfs.sh`.
    nonisolated private static let privilegedMountTransactionScript = #"""
    set -eu
    device="$1"
    driver="$2"
    options="$3"

    case "$device" in
        disk[0-9]*s[0-9]*) ;;
        *) echo "Error: Invalid partition identifier $device" >&2; exit 1 ;;
    esac

    case "$driver" in
        /opt/homebrew/bin/ntfs-3g|/usr/local/bin/ntfs-3g) ;;
        *) echo "Error: Untrusted ntfs-3g driver path $driver" >&2; exit 1 ;;
    esac

    # Verify external partition via diskutil before touching the device
    info_plist=$(/usr/sbin/diskutil info -plist "$device" 2>/dev/null || true)
    if [ -z "$info_plist" ]; then
        echo "Error: Cannot inspect volume $device with diskutil." >&2
        exit 1
    fi

    # [1/4] Create controlled mount point under /Volumes
    new_mount_point=$(/usr/bin/mktemp -d "/Volumes/mountfs.${device}.XXXXXXXX")
    /bin/chmod 755 "$new_mount_point"

    driver_log=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/mountfs-driver.XXXXXXXX")
    recovery_needed=0

    cleanup_and_recover() {
        status=$?
        if [ "$status" -ne 0 ] && [ "$recovery_needed" -eq 1 ]; then
            echo "Recovery: Restoring read-only mount via macOS..." >&2
            /usr/sbin/diskutil unmount "$device" >/dev/null 2>&1 || true
            if /usr/sbin/diskutil mount readOnly "$device" >/dev/null 2>&1; then
                echo "RECOVERY_STATUS=RECOVERED_RO" >&2
            else
                echo "RECOVERY_STATUS=RECOVERY_FAILED" >&2
            fi
        fi
        if [ "$status" -ne 0 ] && [ -n "$new_mount_point" ] && [ -d "$new_mount_point" ]; then
            /bin/rmdir "$new_mount_point" 2>/dev/null || true
        fi
        /bin/rm -f "$driver_log" 2>/dev/null || true
        exit "$status"
    }
    trap cleanup_and_recover EXIT INT TERM

    # [2/4] Unmount existing macOS read-only volume if currently mounted
    recovery_needed=1
    if /sbin/mount | /usr/bin/grep -Eq "^/dev/r?${device} on "; then
        /usr/sbin/diskutil unmount "$device" >/dev/null
    fi

    # [3/4] Mount with ntfs-3g using safe options (norecover)
    if ! "$driver" "/dev/$device" "$new_mount_point" -o "$options" >"$driver_log" 2>&1; then
        /bin/cat "$driver_log" >&2
        exit 1
    fi

    echo "MOUNTFS_MOUNT_POINT=$new_mount_point"
    """#

    nonisolated func enableReadWrite(
        for disk: DiskInfo,
        backend: FilesystemBackendType,
        onStepChange: @Sendable (MountTransactionStep) -> Void
    ) throws -> MountOperationOutcome {
        let device = disk.deviceIdentifier
        onStepChange(.validatingIdentity)

        // 1. Validate BSD partition identifier and safety flags
        guard MountFSEngine.isValidPartitionIdentifier(device) else {
            throw NTFSFilesystemError.invalidDeviceIdentifier(device)
        }
        guard !disk.isInternal, !disk.isWholeDisk else {
            throw NTFSFilesystemError.internalOrWholeDiskRejected("Only external partitions can be mounted read/write")
        }

        // 2. Pin physical IOKit media identity before starting
        guard let expectedIdentity = disk.mediaIdentity ?? MountFSEngine.mediaIdentity(device),
              !expectedIdentity.isEmpty else {
            throw NTFSFilesystemError.missingMediaIdentity(device)
        }
        guard MountFSEngine.mediaIdentity(device) == expectedIdentity else {
            throw NTFSFilesystemError.mediaDisconnectedOrReplaced(device)
        }

        // 3. Check driver and backend availability
        let envStatus = backendService.inspectEnvironment(selectedBackend: backend)
        guard let driverPath = envStatus.ntfs3gPath else {
            throw NTFSFilesystemError.driverNotInstalled(
                "ntfs-3g is not installed. Install macFUSE and ntfs-3g via Homebrew:\n\(envStatus.homebrewInstallCommand)"
            )
        }
        if backend == .fskit && !envStatus.fskitSupportedOnOS {
            throw NTFSFilesystemError.backendUnavailable("The FSKit backend requires macOS 15.4 or later.")
        }
        if backend == .kernel && !envStatus.macFUSEInstalled {
            throw NTFSFilesystemError.backendUnavailable(
                "macFUSE was not found at \(NTFSBackendAdapter.macFUSEBundlePath). Install it with: brew install --cask macfuse"
            )
        }

        // 4. Check current kernel mount state (if already mounted writable, verify and return)
        if let currentState = MountFSEngine.mountState(device),
           let existingPoint = MountFSEngine.verifiedWritableMountPoint(
               expectedIdentity: expectedIdentity,
               observedIdentity: MountFSEngine.mediaIdentity(device),
               mountState: currentState
           ) {
            onStepChange(.verifyingWriteAccess)
            if case .success = NTFSBackendAdapter.verifyUserWriteAccess(atMountPoint: existingPoint) {
                return MountOperationOutcome(
                    device: device,
                    mountPoint: existingPoint,
                    mediaIdentity: expectedIdentity,
                    backend: backend,
                    operationLog: "\(disk.name) (\(device)) is already mounted with verified read/write access at \(existingPoint).",
                    warnings: []
                )
            }
        }

        // 5. Build safe ntfs-3g mount options (always includes norecover to protect hibernated/dirty NTFS volumes)
        let mountOptions = NTFSBackendAdapter.buildMountOptions(
            backend: backend,
            uid: getuid(),
            gid: getgid(),
            volumeLabel: disk.name
        )

        onStepChange(.preparingDirectory)
        onStepChange(.unmountingReadOnly)
        onStepChange(.mountingNTFS3G)

        // 6. Execute transactional privileged mount
        let commandResult = authService.runPrivilegedShellScript(
            Self.privilegedMountTransactionScript,
            arguments: [device, driverPath, mountOptions],
            prompt: "u-NTFS needs administrator permission to enable NTFS write access for \(disk.name).",
            timeout: 180
        )

        let completionStatus = MountFSEngine.mountCompletionStatus(commandResult.status, isMountOperation: true)
        let outputText = commandResult.text

        if completionStatus == 2 {
            throw NTFSFilesystemError.authorizationCancelled
        }
        if completionStatus == 125 {
            throw NTFSFilesystemError.operationUncertain(outputText)
        }

        if completionStatus != 0 {
            let recoveredRO = outputText.contains("RECOVERY_STATUS=RECOVERED_RO")
                || (MountFSEngine.mountState(device)?["MountPoint"] as? String)?.isEmpty == false
            let classified = NTFSBackendAdapter.classifyDriverFailure(
                logText: outputText,
                driverPath: driverPath,
                backend: backend
            )
            if case .mountFailedWithRecovery(let reason, _) = classified.error {
                throw NTFSFilesystemError.mountFailedWithRecovery(reason: reason, recoveredReadOnly: recoveredRO)
            }
            throw classified.error
        }

        // Extract MOUNTFS_MOUNT_POINT from stdout
        let parsedMountPoint = outputText
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("MOUNTFS_MOUNT_POINT=") })
            .map { String($0.dropFirst("MOUNTFS_MOUNT_POINT=".count)).trimmingCharacters(in: .whitespacesAndNewlines) }

        // 7. [4/4] Verify kernel mount state and user-level write access (up to 3 attempts, 1s apart, matching mountfs.sh)
        onStepChange(.verifyingWriteAccess)
        var verifiedPoint: String?
        var lastProbeError: String = "Kernel mount state did not report a writable volume."

        for attempt in 1...3 {
            let observedIdentity = MountFSEngine.mediaIdentity(device)
            guard observedIdentity == expectedIdentity else {
                throw NTFSFilesystemError.mediaDisconnectedOrReplaced(device)
            }

            let state = MountFSEngine.mountState(device)
            if let candidatePoint = MountFSEngine.verifiedWritableMountPoint(
                expectedIdentity: expectedIdentity,
                observedIdentity: observedIdentity,
                mountState: state
            ) {
                if parsedMountPoint == nil || candidatePoint == parsedMountPoint {
                    switch NTFSBackendAdapter.verifyUserWriteAccess(atMountPoint: candidatePoint) {
                    case .success:
                        verifiedPoint = candidatePoint
                    case .failure(let error):
                        lastProbeError = error.localizedDescription
                    }
                }
            }

            if verifiedPoint != nil {
                break
            }
            if attempt < 3 {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        guard let finalMountPoint = verifiedPoint else {
            // Trigger automatic read-only recovery if verification failed
            onStepChange(.recoveringReadOnly)
            let recovered = performFallbackReadOnlyRecovery(device: device, expectedIdentity: expectedIdentity, staleMountPoint: parsedMountPoint)
            throw NTFSFilesystemError.writeVerificationFailed(reason: lastProbeError, recoveredReadOnly: recovered)
        }

        let logSummary = """
        [1/4] Prepared controlled mount directory \(finalMountPoint)
        [2/4] Unmounted macOS read-only NTFS volume on \(device)
        [3/4] Mounted /dev/\(device) with \(driverPath) (\(backend.rawValue))
              Options: \(mountOptions)
        [4/4] Verified kernel mount table and user write probe at \(finalMountPoint)
        Success: Write access enabled for \(disk.name) at \(finalMountPoint)
        """

        return MountOperationOutcome(
            device: device,
            mountPoint: finalMountPoint,
            mediaIdentity: expectedIdentity,
            backend: backend,
            operationLog: logSummary,
            warnings: []
        )
    }

    nonisolated private func performFallbackReadOnlyRecovery(
        device: String,
        expectedIdentity: String,
        staleMountPoint: String?
    ) -> Bool {
        guard MountFSEngine.mediaIdentity(device) == expectedIdentity else { return false }
        _ = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["unmount", device], timeout: 20)
        if let stale = staleMountPoint,
           stale.range(of: "^/Volumes/mountfs\\.\(device)\\.[A-Za-z0-9]+$", options: .regularExpression) != nil {
            _ = authService.runPrivilegedShellScript(
                #"/bin/rmdir "$1" 2>/dev/null || true"#,
                arguments: [stale],
                prompt: "Cleaning up temporary mount directory.",
                timeout: 30
            )
        }
        guard MountFSEngine.mediaIdentity(device) == expectedIdentity else { return false }
        let remount = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["mount", "readOnly", device], timeout: 25)
        return remount.status == 0
    }

    nonisolated func remountReadOnly(for disk: DiskInfo) throws -> String {
        let device = disk.deviceIdentifier
        guard MountFSEngine.isValidPartitionIdentifier(device) else {
            throw NTFSFilesystemError.invalidDeviceIdentifier(device)
        }
        if let expected = disk.mediaIdentity, MountFSEngine.mediaIdentity(device) != expected {
            throw NTFSFilesystemError.mediaDisconnectedOrReplaced(device)
        }

        let previousMountPoint = disk.mountPoint
        if disk.isMounted {
            let unmountResult = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["unmount", device], timeout: 30)
            if unmountResult.status != 0 {
                // Fallback to privileged unmount if mounted by root ntfs-3g
                let privUnmount = authService.runPrivilegedShellScript(
                    #"/usr/sbin/diskutil unmount "$1""#,
                    arguments: [device],
                    prompt: "u-NTFS needs permission to unmount \(disk.name) before remounting read-only.",
                    timeout: 45
                )
                if privUnmount.status == 2 {
                    throw NTFSFilesystemError.authorizationCancelled
                }
                if privUnmount.status != 0 {
                    throw NTFSFilesystemError.commandFailed(privUnmount.text.isEmpty ? unmountResult.text : privUnmount.text)
                }
            }
        }

        // Remove controlled /Volumes/mountfs.<device>.XXXX directory if empty
        if let prev = previousMountPoint,
           prev.range(of: "^/Volumes/mountfs\\.\(device)\\.[A-Za-z0-9]+$", options: .regularExpression) != nil {
            _ = rmdir(prev)
        }

        let mountRO = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["mount", "readOnly", device], timeout: 30)
        guard mountRO.status == 0 else {
            throw NTFSFilesystemError.commandFailed(mountRO.text)
        }
        return mountRO.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func unmountVolume(for disk: DiskInfo) throws -> String {
        let device = disk.deviceIdentifier
        guard MountFSEngine.isValidPartitionIdentifier(device) else {
            throw NTFSFilesystemError.invalidDeviceIdentifier(device)
        }
        if let expected = disk.mediaIdentity, MountFSEngine.mediaIdentity(device) != expected {
            throw NTFSFilesystemError.mediaDisconnectedOrReplaced(device)
        }

        let previousMountPoint = disk.mountPoint
        let result = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["unmount", device], timeout: 30)
        if result.status != 0 {
            let privResult = authService.runPrivilegedShellScript(
                #"/usr/sbin/diskutil unmount "$1" && if [ -n "$2" ] && [ -d "$2" ]; then /bin/rmdir "$2" 2>/dev/null || true; fi"#,
                arguments: [device, previousMountPoint ?? ""],
                prompt: "u-NTFS needs permission to unmount \(disk.name).",
                timeout: 45
            )
            if privResult.status == 2 {
                throw NTFSFilesystemError.authorizationCancelled
            }
            guard privResult.status == 0 else {
                throw NTFSFilesystemError.commandFailed(privResult.text.isEmpty ? result.text : privResult.text)
            }
            return privResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let prev = previousMountPoint,
           prev.range(of: "^/Volumes/mountfs\\.\(device)\\.[A-Za-z0-9]+$", options: .regularExpression) != nil {
            _ = rmdir(prev)
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func safelyEject(for disk: DiskInfo) throws -> String {
        let device = disk.deviceIdentifier
        guard MountFSEngine.isValidPartitionIdentifier(device) else {
            throw NTFSFilesystemError.invalidDeviceIdentifier(device)
        }
        guard let expected = disk.mediaIdentity,
              MountFSEngine.mediaIdentity(device) == expected else {
            throw NTFSFilesystemError.mediaDisconnectedOrReplaced(device)
        }

        let result = MountFSEngine.runBoundedCommand("/usr/sbin/diskutil", ["eject", device], timeout: 45)
        if result.status != 0 {
            let privEject = authService.runPrivilegedShellScript(
                #"/usr/sbin/diskutil eject "$1""#,
                arguments: [device],
                prompt: "u-NTFS needs permission to safely eject \(disk.name).",
                timeout: 60
            )
            if privEject.status == 2 {
                throw NTFSFilesystemError.authorizationCancelled
            }
            guard privEject.status == 0 else {
                throw NTFSFilesystemError.commandFailed(privEject.text.isEmpty ? result.text : privEject.text)
            }
            return privEject.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
