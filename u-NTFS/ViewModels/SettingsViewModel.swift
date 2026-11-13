import Foundation
import Observation
import ServiceManagement

/// Manages persistent application settings as specified in Section 8 of `agents.md` and `guoquan/mountfs`.
@Observable
final class SettingsViewModel {
    private let defaults: UserDefaults

    var autoMountNTFS: Bool {
        didSet { defaults.set(autoMountNTFS, forKey: Keys.autoMountNTFS) }
    }

    var defaultMountWritable: Bool {
        didSet { defaults.set(defaultMountWritable, forKey: Keys.defaultMountWritable) }
    }

    var preferredBackend: FilesystemBackendType {
        didSet { defaults.set(preferredBackend.rawValue, forKey: Keys.preferredBackend) }
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLoginRegistration(enabled: launchAtLogin)
        }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    var showVolumeCountInMenuBar: Bool {
        didSet { defaults.set(showVolumeCountInMenuBar, forKey: Keys.showVolumeCountInMenuBar) }
    }

    var openFinderAfterMount: Bool {
        didSet { defaults.set(openFinderAfterMount, forKey: Keys.openFinderAfterMount) }
    }

    var requireBiometricConfirmation: Bool {
        didSet { defaults.set(requireBiometricConfirmation, forKey: Keys.requireBiometricConfirmation) }
    }

    var enableNotifications: Bool {
        didSet { defaults.set(enableNotifications, forKey: Keys.enableNotifications) }
    }

    var enableDiagnosticLogging: Bool {
        didSet {
            defaults.set(enableDiagnosticLogging, forKey: Keys.enableDiagnosticLogging)
            LoggingService.shared.verboseLoggingEnabled = enableDiagnosticLogging
        }
    }

    var showNonNTFSVolumes: Bool {
        didSet { defaults.set(showNonNTFSVolumes, forKey: Keys.showNonNTFSVolumes) }
    }

    var launchAtLoginStatusDescription: String = "Standard App Session"

    private enum Keys {
        static let autoMountNTFS = "mountfs.autoMountNTFS"
        static let defaultMountWritable = "mountfs.defaultMountWritable"
        static let preferredBackend = "mountfs.preferredBackend"
        static let launchAtLogin = "mountfs.launchAtLogin"
        static let showMenuBarIcon = "mountfs.showMenuBarIcon"
        static let showVolumeCountInMenuBar = "showVolumeCount"
        static let openFinderAfterMount = "openFinderAfterMount"
        static let requireBiometricConfirmation = "touchIDForHelper"
        static let enableNotifications = "mountfs.enableNotifications"
        static let enableDiagnosticLogging = "mountfs.enableDiagnosticLogging"
        static let showNonNTFSVolumes = "mountfs.showNonNTFSVolumes"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoMountNTFS: false,
            Keys.defaultMountWritable: true,
            Keys.preferredBackend: FilesystemBackendType.kernel.rawValue,
            Keys.launchAtLogin: false,
            Keys.showMenuBarIcon: true,
            Keys.showVolumeCountInMenuBar: true,
            Keys.openFinderAfterMount: true,
            Keys.requireBiometricConfirmation: false,
            Keys.enableNotifications: true,
            Keys.enableDiagnosticLogging: true,
            Keys.showNonNTFSVolumes: false
        ])

        self.autoMountNTFS = defaults.bool(forKey: Keys.autoMountNTFS)
        self.defaultMountWritable = defaults.bool(forKey: Keys.defaultMountWritable)
        let rawBackend = defaults.string(forKey: Keys.preferredBackend) ?? FilesystemBackendType.kernel.rawValue
        self.preferredBackend = FilesystemBackendType(rawValue: rawBackend) ?? .kernel
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        self.showVolumeCountInMenuBar = defaults.bool(forKey: Keys.showVolumeCountInMenuBar)
        self.openFinderAfterMount = defaults.bool(forKey: Keys.openFinderAfterMount)
        self.requireBiometricConfirmation = defaults.bool(forKey: Keys.requireBiometricConfirmation)
        self.enableNotifications = defaults.bool(forKey: Keys.enableNotifications)
        self.enableDiagnosticLogging = defaults.bool(forKey: Keys.enableDiagnosticLogging)
        self.showNonNTFSVolumes = defaults.bool(forKey: Keys.showNonNTFSVolumes)
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginStatusDescription = "Enabled in Login Items"
        case .requiresApproval:
            launchAtLoginStatusDescription = "Requires approval in System Settings → Login Items"
        case .notRegistered:
            launchAtLoginStatusDescription = "Not registered"
        case .notFound:
            launchAtLoginStatusDescription = "Available when moved to /Applications"
        @unknown default:
            launchAtLoginStatusDescription = "Unknown"
        }
    }

    private func updateLaunchAtLoginRegistration(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            LoggingService.shared.log(
                "Launch at Login update notice: \(error.localizedDescription)",
                level: .warning,
                category: "Settings"
            )
            refreshLaunchAtLoginStatus()
        }
    }
}
