import Foundation

/// Protocol for formatting external disks and partitions to Windows NTFS.
protocol DiskFormatServicing: Sendable {
    nonisolated func findMkntfsExecutable() -> String?
    nonisolated func formatAsNTFS(
        disk: DiskInfo,
        volumeLabel: String,
        quickFormat: Bool,
        wholeDiskErase: Bool
    ) async -> Result<String, Error>
}

/// Service handling external drive partition unmounting, MBR/GPT partitioning,
/// and low-level `mkntfs` file system creation with administrator privileges.
final class DiskFormatService: DiskFormatServicing, @unchecked Sendable {
    static let shared = DiskFormatService()

    private let authService: AuthorizationServicing

    init(authService: AuthorizationServicing = AuthorizationService()) {
        self.authService = authService
    }

    // MARK: - Binary Resolution

    nonisolated func findMkntfsExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/sbin/mkntfs",
            "/opt/homebrew/bin/mkntfs",
            "/usr/local/sbin/mkntfs",
            "/usr/local/bin/mkntfs"
        ]

        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Check Cellar wildcards if not symlinked into sbin
        let cellarPaths = [
            "/opt/homebrew/Cellar/ntfs-3g-mac",
            "/usr/local/Cellar/ntfs-3g-mac"
        ]
        for cellar in cellarPaths {
            if let versions = try? fm.contentsOfDirectory(atPath: cellar) {
                for version in versions {
                    let binary = "\(cellar)/\(version)/sbin/mkntfs"
                    if fm.isExecutableFile(atPath: binary) {
                        return binary
                    }
                }
            }
        }

        return nil
    }

    // MARK: - NTFS Formatting Execution

    nonisolated func formatAsNTFS(
        disk: DiskInfo,
        volumeLabel: String,
        quickFormat: Bool = true,
        wholeDiskErase: Bool = true
    ) async -> Result<String, Error> {
        // Strict Hardware Invariant Check: Never touch internal system disks
        guard !disk.isInternal else {
            let err = NSError(
                domain: "DiskFormatService",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Formatting internal system disks is strictly prohibited for data safety."]
            )
            return .failure(err)
        }

        guard let mkntfs = findMkntfsExecutable() else {
            let err = NSError(
                domain: "DiskFormatService",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: "mkntfs utility is not installed. Please install NTFS-3G drivers first via Settings."]
            )
            return .failure(err)
        }

        // Clean & sanitize volume label (max 32 chars, remove disallowed NTFS characters)
        let cleanedLabel = sanitizeNTFSVolumeLabel(volumeLabel)
        let parentDisk = disk.parentWholeDisk.isEmpty ? disk.deviceIdentifier : disk.parentWholeDisk
        let targetPartition = wholeDiskErase ? "\(parentDisk)s1" : disk.deviceIdentifier

        // Build mkntfs command:
        // -f: quick format
        // -F: force execution even if filesystem already exists
        // -L: volume label
        var mkntfsArgs = ["-F"]
        if quickFormat {
            mkntfsArgs.append("-f")
        }
        mkntfsArgs.append(contentsOf: ["-L", "\"\(cleanedLabel)\""])

        let rawDevice = "/dev/r\(targetPartition)"
        let blockDevice = "/dev/\(targetPartition)"
        let mkntfsOptions = mkntfsArgs.joined(separator: " ")

        // Robust shell script:
        // 1. Unmount existing partitions
        // 2. Erase with ExFAT personality to establish partition type 0x07 (Windows_NTFS / Microsoft Basic Data)
        // 3. Unmount before raw sector writing
        // 4. Run mkntfs to lay down the genuine NTFS Boot Sector, BPB, $MFT, and journal
        // 5. Mount the newly created NTFS volume so macOS recognizes it
        let script: String
        if wholeDiskErase {
            script = """
            set -e
            /usr/sbin/diskutil unmountDisk /dev/\(parentDisk) || true
            /usr/sbin/diskutil eraseDisk ExFAT "\(cleanedLabel)" MBR /dev/\(parentDisk)
            /usr/sbin/diskutil unmount /dev/\(targetPartition) || true
            \(mkntfs) \(mkntfsOptions) \(rawDevice) || \(mkntfs) \(mkntfsOptions) \(blockDevice)
            /usr/sbin/diskutil mount /dev/\(targetPartition) || true
            """
        } else {
            script = """
            set -e
            /usr/sbin/diskutil unmount /dev/\(targetPartition) || true
            /usr/sbin/diskutil eraseVolume ExFAT "\(cleanedLabel)" /dev/\(targetPartition)
            /usr/sbin/diskutil unmount /dev/\(targetPartition) || true
            \(mkntfs) \(mkntfsOptions) \(rawDevice) || \(mkntfs) \(mkntfsOptions) \(blockDevice)
            /usr/sbin/diskutil mount /dev/\(targetPartition) || true
            """
        }

        let result = authService.runPrivilegedShellScript(
            script,
            arguments: [],
            prompt: "u-NTFS needs administrator privileges to format \(disk.name) (/dev/\(disk.deviceIdentifier)) as NTFS.",
            timeout: quickFormat ? 180 : 1800
        )

        let outputString = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if result.status == 0 {
            return .success("Volume \(cleanedLabel) successfully formatted as NTFS!\n\n\(outputString)")
        } else {
            let errorMsg = outputString.isEmpty ? "Process exited with status code \(result.status)" : outputString
            let err = NSError(
                domain: "DiskFormatService",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "Formatting failed:\n\(errorMsg)"]
            )
            return .failure(err)
        }
    }

    private nonisolated func sanitizeNTFSVolumeLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "UNTFS"
        }
        // Characters disallowed in FAT/NTFS volume labels: \ / : * ? " < > |
        let disallowed = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = trimmed.components(separatedBy: disallowed).joined()
        return String(cleaned.prefix(32))
    }
}
