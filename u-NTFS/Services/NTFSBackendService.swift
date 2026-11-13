import Foundation
import AppKit

/// Protocol for inspecting and diagnosing the NTFS driver and FUSE/FSKit backend environment.
protocol NTFSBackendServicing: Sendable {
    nonisolated func inspectEnvironment(selectedBackend: FilesystemBackendType) -> BackendEnvironmentStatus
    nonisolated func generateInstallationDiagnosis(selectedBackend: FilesystemBackendType) -> String
    nonisolated func findHomebrewExecutable() -> String?
    nonisolated func installMissingDrivers(selectedBackend: FilesystemBackendType) -> Result<String, Error>
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

    nonisolated func findHomebrewExecutable() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    nonisolated func installMissingDrivers(selectedBackend: FilesystemBackendType) -> Result<String, Error> {
        let initialStatus = inspectEnvironment(selectedBackend: selectedBackend)
        var logLines: [String] = []
        logLines.append("=== u-NTFS Automatic Driver Installer ===")
        logLines.append("Target Backend: \(selectedBackend.displayName)")

        guard let brewPath = findHomebrewExecutable() else {
            let msg = "Homebrew ('brew') was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew.\nPlease install Homebrew from https://brew.sh first, or use 'Install in Terminal' to run the setup."
            logLines.append("Error: \(msg)")
            return .failure(NSError(
                domain: "uNTFS.DriverInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))
        }

        logLines.append("Using Homebrew: \(brewPath)")

        let userHome = NSHomeDirectory()
        let userEnv: [String: String] = [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": userHome,
            "LANG": "en_US.UTF-8",
            "NONINTERACTIVE": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1"
        ]

        // 1. Install macFUSE or FUSE-T if missing
        if selectedBackend == .fuseT && !initialStatus.fuseTInstalled {
            logLines.append("\n[1/2] Installing FUSE-T (brew install --cask fuse-t)...")
            let tapRes = MountFSEngine.runBoundedCommand(
                brewPath,
                ["tap", "macos-fuse-t/homebrew-cask"],
                environment: userEnv,
                mergeErrors: true,
                timeout: 180
            )
            logLines.append(tapRes.text)

            let caskRes = MountFSEngine.runBoundedCommand(
                brewPath,
                ["install", "--cask", "fuse-t"],
                environment: userEnv,
                mergeErrors: true,
                timeout: 600
            )
            logLines.append(caskRes.text)
            if caskRes.status != 0 {
                return .failure(NSError(
                    domain: "uNTFS.DriverInstaller",
                    code: Int(caskRes.status),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to install FUSE-T via Homebrew.\n\n\(logLines.joined(separator: "\n"))"]
                ))
            }
        } else if !initialStatus.macFUSEInstalled {
            logLines.append("\n[1/2] Installing macFUSE (brew install --cask macfuse)...")
            let caskRes = MountFSEngine.runBoundedCommand(
                brewPath,
                ["install", "--cask", "macfuse"],
                environment: userEnv,
                mergeErrors: true,
                timeout: 600
            )
            logLines.append(caskRes.text)
            if caskRes.status != 0 {
                return .failure(NSError(
                    domain: "uNTFS.DriverInstaller",
                    code: Int(caskRes.status),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to install macFUSE via Homebrew. Note: Cask installation may require administrator password in Terminal.\n\n\(logLines.joined(separator: "\n"))"]
                ))
            }
        } else {
            logLines.append("\n[1/2] Filesystem bundle already installed.")
        }

        // 2. Install ntfs-3g-mac if missing
        let afterBundleStatus = inspectEnvironment(selectedBackend: selectedBackend)
        if !afterBundleStatus.hasNTFS3G {
            logLines.append("\n[2/2] Installing ntfs-3g-mac (brew install gromgit/fuse/ntfs-3g-mac)...")
            let ntfsRes = MountFSEngine.runBoundedCommand(
                brewPath,
                ["install", "gromgit/fuse/ntfs-3g-mac"],
                environment: userEnv,
                mergeErrors: true,
                timeout: 600
            )
            logLines.append(ntfsRes.text)
            if ntfsRes.status != 0 {
                return .failure(NSError(
                    domain: "uNTFS.DriverInstaller",
                    code: Int(ntfsRes.status),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to install ntfs-3g-mac via Homebrew.\n\n\(logLines.joined(separator: "\n"))"]
                ))
            }
        } else {
            logLines.append("\n[2/2] ntfs-3g executable already installed at \(afterBundleStatus.ntfs3gPath ?? "").")
        }

        let finalStatus = inspectEnvironment(selectedBackend: selectedBackend)
        logLines.append("\n=== Installation Summary ===")
        logLines.append("ntfs-3g: \(finalStatus.ntfs3gPath ?? "Not Found")")
        logLines.append("macFUSE: \(finalStatus.macFUSEInstalled ? "Installed" : "Not Installed")")
        logLines.append("Status: \(finalStatus.readinessDescription)")

        return .success(logLines.joined(separator: "\n"))
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
