import Foundation

/// Supported NTFS filesystem backends following the mouNTFS architecture.
nonisolated enum FilesystemBackendType: String, CaseIterable, Identifiable, Codable, Sendable {
    case kernel = "kernel"
    case fskit = "fskit"
    case fuseT = "fuset"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kernel:
            return "macFUSE + NTFS-3G (Kernel)"
        case .fskit:
            return "Apple FSKit + NTFS-3G (Experimental)"
        case .fuseT:
            return "FUSE-T + NTFS-3G (User-Space)"
        }
    }

    var shortName: String {
        switch self {
        case .kernel:
            return "macFUSE (Kernel)"
        case .fskit:
            return "Apple FSKit"
        case .fuseT:
            return "FUSE-T"
        }
    }

    var summary: String {
        switch self {
        case .kernel:
            return "Default u-NTFS engine using macFUSE (/Library/Filesystems/macfuse.fs) and Homebrew ntfs-3g."
        case .fskit:
            return "Experimental Apple FSKit user-space backend (-o backend=fskit). Requires macOS 15.4 or later."
        case .fuseT:
            return "Kext-free user-space FUSE backend paired with ntfs-3g."
        }
    }

    var mountOptionFlag: String {
        switch self {
        case .kernel, .fuseT:
            return "local"
        case .fskit:
            return "backend=fskit"
        }
    }
}

/// Real-time installation and readiness state of the NTFS driver environment.
nonisolated struct BackendEnvironmentStatus: Equatable, Sendable {
    let ntfs3gPath: String?
    let macFUSEInstalled: Bool
    let fuseTInstalled: Bool
    let fskitSupportedOnOS: Bool
    let macosVersion: String
    let architecture: String
    let selectedBackend: FilesystemBackendType

    var hasNTFS3G: Bool {
        ntfs3gPath != nil
    }

    var isSelectedBackendReady: Bool {
        guard hasNTFS3G else { return false }
        switch selectedBackend {
        case .kernel:
            return macFUSEInstalled
        case .fskit:
            return fskitSupportedOnOS && macFUSEInstalled
        case .fuseT:
            return fuseTInstalled || macFUSEInstalled
        }
    }

    var readinessDescription: String {
        if !hasNTFS3G {
            return "ntfs-3g driver not found (/opt/homebrew/bin/ntfs-3g)"
        }
        switch selectedBackend {
        case .kernel:
            return macFUSEInstalled
                ? "Ready (\(selectedBackend.shortName))"
                : "macFUSE bundle missing (/Library/Filesystems/macfuse.fs)"
        case .fskit:
            if !fskitSupportedOnOS {
                return "FSKit requires macOS 15.4 or later"
            }
            return macFUSEInstalled
                ? "Ready (Experimental FSKit)"
                : "Compatible macFUSE/FSKit bundle missing"
        case .fuseT:
            return (fuseTInstalled || macFUSEInstalled)
                ? "Ready (FUSE-T)"
                : "FUSE-T bundle missing (/Library/Filesystems/fuse-t.fs)"
        }
    }

    var homebrewInstallCommand: String {
        "brew install --cask macfuse && brew install gromgit/fuse/ntfs-3g-mac"
    }
}
