import Foundation
import AppKit

/// Protocol for auditing system-wide drivers, permissions, and extension authorizations.
protocol SystemReadinessServicing: Sendable {
    nonisolated func performAudit(selectedBackend: FilesystemBackendType) -> [ReadinessCheckItem]
    func openPrivacySecurity()
    func openFullDiskAccess()
}

/// Service auditing macOS system extensions, driver binaries, Full Disk Access, and formatting tools.
final class SystemReadinessService: SystemReadinessServicing, @unchecked Sendable {
    static let shared = SystemReadinessService()

    private let backendService: NTFSBackendServicing

    init(backendService: NTFSBackendServicing = NTFSBackendService()) {
        self.backendService = backendService
    }

    nonisolated func performAudit(selectedBackend: FilesystemBackendType) -> [ReadinessCheckItem] {
        var items: [ReadinessCheckItem] = []
        let fm = FileManager.default

        // 1. Homebrew Package Manager
        let brewPath = backendService.findHomebrewExecutable()
        if let brew = brewPath {
            items.append(
                ReadinessCheckItem(
                    id: "homebrew",
                    category: .drivers,
                    title: "Homebrew Package Manager",
                    subtitle: "Installed at \(brew)",
                    status: .ready,
                    detailedInstruction: "Homebrew is available to manage third-party NTFS driver updates."
                )
            )
        } else {
            items.append(
                ReadinessCheckItem(
                    id: "homebrew",
                    category: .drivers,
                    title: "Homebrew Package Manager",
                    subtitle: "Not found in standard paths",
                    status: .notInstalled("Required to fetch NTFS-3G and FUSE drivers."),
                    detailedInstruction: "Install Homebrew from https://brew.sh or run `/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"` in Terminal.",
                    actionTitle: "Install Drivers Automatically",
                    actionType: .installDrivers
                )
            )
        }

        // 2. NTFS-3G Driver
        let ntfs3gPath = NTFSBackendAdapter.findDriver(fileManager: fm)
        if let ntfs3g = ntfs3gPath {
            items.append(
                ReadinessCheckItem(
                    id: "ntfs3g",
                    category: .drivers,
                    title: "NTFS-3G Driver Binary",
                    subtitle: "Installed at \(ntfs3g)",
                    status: .ready,
                    detailedInstruction: "Provides transparent POSIX read-write NTFS filesystem capabilities."
                )
            )
        } else {
            items.append(
                ReadinessCheckItem(
                    id: "ntfs3g",
                    category: .drivers,
                    title: "NTFS-3G Driver Binary",
                    subtitle: "Missing ntfs-3g binary",
                    status: .notInstalled("Read/write NTFS mounting requires the ntfs-3g package."),
                    detailedInstruction: "Install ntfs-3g via Homebrew (`brew install gromgit/fuse/ntfs-3g-mac`).",
                    actionTitle: "Install Missing Drivers",
                    actionType: .installDrivers
                )
            )
        }

        // 3. FUSE Runtime Engine (macFUSE / FUSE-T / FSKit)
        var isDir: ObjCBool = false
        let macFUSEInstalled = fm.fileExists(atPath: NTFSBackendAdapter.macFUSEBundlePath, isDirectory: &isDir) && isDir.boolValue
        var isFuseTDir: ObjCBool = false
        let fuseTInstalled = fm.fileExists(atPath: NTFSBackendAdapter.fuseTBundlePath, isDirectory: &isFuseTDir) && isFuseTDir.boolValue

        switch selectedBackend {
        case .kernel:
            if macFUSEInstalled {
                // Check if macFUSE kernel extension is loaded or blocked
                let kextCheck = MountFSEngine.runBoundedCommand("/usr/bin/kmutil", ["showloaded", "--bundle-identifier", "io.macfuse.filesystems.macfuse"], mergeErrors: true, timeout: 4)
                let isKextLoaded = kextCheck.status == 0 && kextCheck.text.contains("io.macfuse.filesystems.macfuse")

                if isKextLoaded {
                    items.append(
                        ReadinessCheckItem(
                            id: "fuse_runtime",
                            category: .drivers,
                            title: "macFUSE Kernel Runtime",
                            subtitle: "Installed & active at /Library/Filesystems/macfuse.fs",
                            status: .ready,
                            detailedInstruction: "macFUSE kernel subsystem is fully active."
                        )
                    )
                } else {
                    items.append(
                        ReadinessCheckItem(
                            id: "fuse_runtime",
                            category: .permissions,
                            title: "macFUSE System Extension Approval",
                            subtitle: "System Extension Blocked by macOS",
                            status: .blocked("System software from developer 'Benjamin Fleischer' was blocked by macOS Security."),
                            detailedInstruction: "Open System Settings → Privacy & Security, scroll down to the Security section, and click 'Allow' next to Benjamin Fleischer. A restart may be required. Alternatively, switch to FUSE-T which never requires kernel extension approval.",
                            actionTitle: "Open Privacy & Security Settings",
                            actionType: .openPrivacySecurity
                        )
                    )
                }
            } else {
                items.append(
                    ReadinessCheckItem(
                        id: "fuse_runtime",
                        category: .drivers,
                        title: "macFUSE Driver Bundle",
                        subtitle: "Missing /Library/Filesystems/macfuse.fs",
                        status: .notInstalled("macFUSE is required for the kernel backend."),
                        detailedInstruction: "Install macFUSE via `brew install --cask macfuse` or switch to the kext-free FUSE-T backend.",
                        actionTitle: "Install macFUSE",
                        actionType: .installDrivers
                    )
                )
            }

        case .fuseT:
            if fuseTInstalled || macFUSEInstalled {
                items.append(
                    ReadinessCheckItem(
                        id: "fuse_runtime",
                        category: .drivers,
                        title: "FUSE-T User-Space Engine",
                        subtitle: "Active (No Kernel Extension Required)",
                        status: .ready,
                        detailedInstruction: "FUSE-T runs entirely in user-space via NFS loopback. It bypasses Apple System Extension blocks and requires no system reboot or recovery mode."
                    )
                )
            } else {
                items.append(
                    ReadinessCheckItem(
                        id: "fuse_runtime",
                        category: .drivers,
                        title: "FUSE-T Engine (Kext-Free)",
                        subtitle: "Not yet installed",
                        status: .notInstalled("FUSE-T provides kext-free user-space mounting without System Extension blocks."),
                        detailedInstruction: "Install FUSE-T via `brew install --cask mac-fuse-t/homebrew-cask/fuse-t` to avoid kernel extension prompts forever.",
                        actionTitle: "Install FUSE-T",
                        actionType: .installFuseT
                    )
                )
            }

        case .fskit:
            let fskitSupported = NTFSBackendAdapter.isFSKitSupportedOnCurrentOS()
            items.append(
                ReadinessCheckItem(
                    id: "fuse_runtime",
                    category: .drivers,
                    title: "Apple FSKit Engine",
                    subtitle: fskitSupported ? "macOS 15.4+ FSKit Supported" : "Requires macOS 15.4+",
                    status: fskitSupported ? .ready : .warning("Available on macOS 15.4 or later"),
                    detailedInstruction: "Apple's native user-space filesystem kit architecture."
                )
            )
        }

        // 4. macOS Full Disk Access (Privacy & Security)
        items.append(
            ReadinessCheckItem(
                id: "full_disk_access",
                category: .permissions,
                title: "Full Disk Access (FDA)",
                subtitle: "Access to raw block devices (/dev/rdisk*)",
                status: .optional("Recommended for formatting and direct sector telemetry."),
                detailedInstruction: "If disk formatting or mounting fails with 'Operation not permitted', ensure u-NTFS has Full Disk Access in System Settings → Privacy & Security → Full Disk Access.",
                actionTitle: "Open Full Disk Access Settings",
                actionType: .openFullDiskAccess
            )
        )

        // 5. mkntfs Formatting Utility
        let mkntfsPath = DiskFormatService.shared.findMkntfsExecutable()
        if let mkntfs = mkntfsPath {
            items.append(
                ReadinessCheckItem(
                    id: "mkntfs",
                    category: .hardware,
                    title: "NTFS Formatting Utility (mkntfs)",
                    subtitle: "Available at \(mkntfs)",
                    status: .ready,
                    detailedInstruction: "Enables zeroing and initializing external USB/Thunderbolt drives with genuine Windows NTFS file systems."
                )
            )
        } else {
            items.append(
                ReadinessCheckItem(
                    id: "mkntfs",
                    category: .hardware,
                    title: "NTFS Formatting Utility (mkntfs)",
                    subtitle: "Not found",
                    status: .warning("Included with ntfs-3g-mac package."),
                    detailedInstruction: "Format NTFS feature requires `mkntfs`. Install via `brew install gromgit/fuse/ntfs-3g-mac`.",
                    actionTitle: "Install Driver",
                    actionType: .installDrivers
                )
            )
        }

        // 6. Alternative Solution Recommendation (FUSE-T) if user is on kernel mode and experiencing block
        if selectedBackend == .kernel && !fuseTInstalled {
            items.append(
                ReadinessCheckItem(
                    id: "kext_alternative",
                    category: .permissions,
                    title: "Avoid Extension Prompts with FUSE-T",
                    subtitle: "Kext-Free Alternative Available",
                    status: .optional("No reboot or System Settings approval required."),
                    detailedInstruction: "If you do not want to allow kernel extensions or restart your Mac, switch to FUSE-T in Filesystem Engine settings.",
                    actionTitle: "Switch to FUSE-T",
                    actionType: .switchToFuseT
                )
            )
        }

        return items
    }

    func openPrivacySecurity() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Security") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
