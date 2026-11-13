import Foundation
import AppKit

/// Protocol for inspecting and diagnosing the NTFS driver and FUSE/FSKit backend environment.
protocol NTFSBackendServicing: Sendable {
    nonisolated func inspectEnvironment(selectedBackend: FilesystemBackendType) -> BackendEnvironmentStatus
    nonisolated func generateInstallationDiagnosis(selectedBackend: FilesystemBackendType) -> String
    func openFullDiskAccessSettings()
    func openLoginItemsSettings()
}

/// Concrete implementation of `NTFSBackendServicing` ported from `diagnose_installation` in `guoquan/mountfs/mountfs.sh`.
final class NTFSBackendService: NTFSBackendServicing, @unchecked Sendable {

    nonisolated init() {}

    nonisolated func inspectEnvironment(selectedBackend: FilesystemBackendType) -> BackendEnvironmentStatus {
        let fm = FileManager.default
        let driverPath = NTFSBackendAdapter.findDriver(fileManager: fm)
        var isDir: ObjCBool = false
        let macFUSEPresent = fm.fileExists(atPath: NTFSBackendAdapter.macFUSEBundlePath, isDirectory: &isDir) && isDir.boolValue
        var isFuseTDir: ObjCBool = false
        let fuseTPresent = fm.fileExists(atPath: NTFSBackendAdapter.fuseTBundlePath, isDirectory: &isFuseTDir) && isFuseTDir.boolValue
        let fskitSupported = NTFSBackendAdapter.isFSKitSupportedOnCurrentOS()

        let swVers = MountFSEngine.runBoundedCommand("/usr/bin/sw_vers", ["-productVersion"], mergeErrors: false, timeout: 5)
        let macosVersion = swVers.status == 0
            ? swVers.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : ProcessInfo.processInfo.operatingSystemVersionString

        let uname = MountFSEngine.runBoundedCommand("/usr/bin/uname", ["-m"], mergeErrors: false, timeout: 5)
        let arch = uname.status == 0
            ? uname.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : "arm64"

        return BackendEnvironmentStatus(
            ntfs3gPath: driverPath,
            macFUSEInstalled: macFUSEPresent,
            fuseTInstalled: fuseTPresent,
            fskitSupportedOnOS: fskitSupported,
            macosVersion: macosVersion,
            architecture: arch,
            selectedBackend: selectedBackend
        )
    }

    /// Produces the full diagnostic report matching `diagnose_installation` in `mountfs.sh`.
    nonisolated func generateInstallationDiagnosis(selectedBackend: FilesystemBackendType) -> String {
        let status = inspectEnvironment(selectedBackend: selectedBackend)
        var lines: [String] = []
        lines.append("mouNTFS installation check")
        lines.append("macOS: \(status.macosVersion) (\(status.architecture))")
        lines.append("Selected backend: \(selectedBackend.rawValue)")

        if let driver = status.ntfs3gPath {
            lines.append("ntfs-3g: \(driver)")
            let versionResult = MountFSEngine.runBoundedCommand(driver, ["--version"], mergeErrors: true, timeout: 5)
            let firstLine = versionResult.text.components(separatedBy: .newlines).first ?? ""
            if !firstLine.isEmpty {
                lines.append("ntfs-3g version: \(firstLine)")
            }
        } else {
            lines.append("ntfs-3g: not found (checked /opt/homebrew/bin/ntfs-3g and /usr/local/bin/ntfs-3g)")
        }

        if status.macFUSEInstalled {
            lines.append("macFUSE bundle: \(NTFSBackendAdapter.macFUSEBundlePath)")
        } else {
            lines.append("macFUSE bundle: not found at \(NTFSBackendAdapter.macFUSEBundlePath)")
        }

        if status.fuseTInstalled {
            lines.append("FUSE-T bundle: \(NTFSBackendAdapter.fuseTBundlePath)")
        }

        switch selectedBackend {
        case .fskit:
            if status.fskitSupportedOnOS {
                lines.append("FSKit requirement: macOS 15.4+ satisfied")
            } else {
                lines.append("FSKit requirement: requires macOS 15.4 or later")
            }
        case .kernel:
            lines.append("Kernel backend requirement: Approve the macFUSE system extension in System Settings → Privacy & Security if macOS blocks loading.")
        case .fuseT:
            lines.append("FUSE-T backend requirement: Uses user-space loopback mount with ntfs-3g.")
        }

        lines.append("Full Disk Access note: If mounting fails with 'Operation not permitted', add \(status.ntfs3gPath ?? "/opt/homebrew/bin/ntfs-3g") in System Settings → Privacy & Security → Full Disk Access.")
        lines.append("Safety policy: Mounts with -o rw,norecover,allow_other,default_permissions (never clears dirty journals or hibernation files automatically).")
        return lines.joined(separator: "\n")
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
