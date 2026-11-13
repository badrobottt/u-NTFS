import Foundation
import AppKit
import Observation
import UserNotifications

/// Presentation alert model for errors, permissions, and diagnostic messages.
struct DashboardAlertItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let detailedLog: String?
    let offerFullDiskAccess: Bool
    let offerInstallCheck: Bool
}

/// Primary coordinator ViewModel managing external NTFS volume discovery, real-time DiskArbitration updates,
/// transactional read/write mounting, and diagnostics.
@Observable
final class DashboardViewModel {
    var settings: SettingsViewModel
    let logging: LoggingService
    private let volumeService: VolumeInformationServicing
    private let backendService: NTFSBackendServicing
    private let mountService: MountServicing
    private let authService: AuthorizationServicing
    private let diskMonitor: DiskMonitoringService
    private let healthService: DiskHealthServicing

    // System Readiness & Permissions Audit State
    let readinessService: SystemReadinessServicing
    private(set) var readinessItems: [ReadinessCheckItem] = []
    var isShowingReadinessSheet: Bool = false

    var overallReadinessStatus: ReadinessStatus {
        if readinessItems.contains(where: { if case .blocked = $0.status { return true } else { return false } }) {
            return .blocked("Action Required")
        }
        if readinessItems.contains(where: { if case .notInstalled = $0.status { return true } else { return false } }) {
            return .notInstalled("Drivers Missing")
        }
        if readinessItems.contains(where: { if case .warning = $0.status { return true } else { return false } }) {
            return .warning("Attention Needed")
        }
        return .ready
    }

    private var allDisks: [DiskInfo] = []
    private(set) var disks: [DiskInfo] = []
    var selectedDiskID: String? {
        didSet {
            if let disk = selectedDisk {
                fetchHealth(for: disk)
            }
        }
    }

    private(set) var backendEnvironment: BackendEnvironmentStatus
    private(set) var isScanning: Bool = false
    private(set) var isBusy: Bool = false
    private(set) var isInstallingDrivers: Bool = false
    private(set) var driverInstallProgressText: String?
    private(set) var activeDeviceID: String?
    private(set) var activeTransactionStep: MountTransactionStep?
    private(set) var statusSummary: String = "Scanning volumes…"

    var activeAlert: DashboardAlertItem?
    var isShowingDiagnosticsSheet: Bool = false
    var diagnosticsSheetMode: DiagnosticsTab = .logs

    // CrystalDiskInfo-style Health & Telemetry State
    private(set) var diskHealthCache: [String: DiskHealthInfo] = [:]
    private(set) var isLoadingHealth: Bool = false
    private(set) var isInstallingSmartctl: Bool = false
    private(set) var smartctlInstallProgress: String? = nil
    var isShowingHealthSheet: Bool = false

    // NTFS Disk Formatting State
    private let formatService: DiskFormatServicing
    private(set) var isFormattingDisk: Bool = false
    private(set) var formatProgressText: String? = nil
    var isShowingFormatSheet: Bool = false

    /// Retains verified `iomedia` identities across `ntfs-3g` remounts (`verifiedIdentities` in `guoquan/mountfs`).
    private var verifiedIdentities: [String: String] = [:]
    /// Tracks devices already auto-mounted in this connection session to avoid repeat prompts.
    private var autoMountedIdentities: Set<String> = []
    private var scanGeneration: Int = 0

    enum DiagnosticsTab: String, CaseIterable, Identifiable {
        case logs = "Activity Logs"
        case installation = "Driver & Backend"
        case scanReport = "Disk Scan Report"
        case selfTests = "Self-Tests"
        var id: String { rawValue }
    }

    var selectedDisk: DiskInfo? {
        if let selectedDiskID, let match = disks.first(where: { $0.id == selectedDiskID }) {
            return match
        }
        return disks.first
    }

    var writableCount: Int {
        disks.filter(\.isWritable).count
    }

    init(
        settings: SettingsViewModel = SettingsViewModel(),
        logging: LoggingService = .shared,
        volumeService: VolumeInformationServicing = VolumeInformationService(),
        backendService: NTFSBackendServicing = NTFSBackendService(),
        authService: AuthorizationServicing = AuthorizationService(),
        mountService: MountServicing? = nil,
        diskMonitor: DiskMonitoringService = DiskMonitoringService(),
        healthService: DiskHealthServicing = DiskHealthService.shared,
        formatService: DiskFormatServicing = DiskFormatService.shared,
        readinessService: SystemReadinessServicing = SystemReadinessService.shared,
        startMonitoringImmediately: Bool = true
    ) {
        self.settings = settings
        self.logging = logging
        self.volumeService = volumeService
        self.backendService = backendService
        self.authService = authService
        self.mountService = mountService ?? MountService(
            volumeService: volumeService,
            backendService: backendService,
            authService: authService
        )
        self.diskMonitor = diskMonitor
        self.healthService = healthService
        self.formatService = formatService
        self.readinessService = readinessService
        self.backendEnvironment = backendService.inspectEnvironment(selectedBackend: settings.preferredBackend)

        auditSystemReadiness()

        if startMonitoringImmediately {
            startMonitoring()
            refreshAll()
        }
    }

    func startMonitoring() {
        diskMonitor.startMonitoring { [weak self] event in
            guard let self else { return }
            switch event {
            case .diskAppeared(let bsdName):
                self.logging.log("DiskArbitration: disk appeared (\(bsdName))", level: .info, category: "DiskMonitor")
                self.refreshDisks(triggerAutoMountIfNeeded: true)
            case .diskDisappeared(let bsdName):
                self.logging.log("DiskArbitration: disk disappeared (\(bsdName))", level: .info, category: "DiskMonitor")
                self.verifiedIdentities.removeValue(forKey: bsdName)
                self.refreshDisks(triggerAutoMountIfNeeded: false)
            case .diskDescriptionChanged(let bsdName):
                self.logging.log("DiskArbitration: description changed (\(bsdName))", level: .info, category: "DiskMonitor")
                self.refreshDisks(triggerAutoMountIfNeeded: false)
            case .workspaceMountChanged:
                self.refreshDisks(triggerAutoMountIfNeeded: false)
            case .periodicRefresh:
                if !self.isBusy && !self.isScanning {
                    self.refreshDisks(triggerAutoMountIfNeeded: false)
                }
            }
        }
    }

    func refreshAll() {
        refreshBackendStatus()
        auditSystemReadiness()
        refreshDisks(triggerAutoMountIfNeeded: true)
    }

    func refreshBackendStatus() {
        let selected = settings.preferredBackend
        let env = backendService.inspectEnvironment(selectedBackend: selected)
        backendEnvironment = env
    }

    func refreshDisks(triggerAutoMountIfNeeded: Bool = false) {
        guard !isBusy, !isScanning else { return }
        isScanning = true
        let currentIdentities = verifiedIdentities
        let generation = scanGeneration
        let service = volumeService

        Task.detached(priority: .utility) {
            // Always discover all external partitions so UI filtering happens instantaneously (0ms)
            let scanResult = service.scanExternalNTFSVolumes(
                verifiedIdentities: currentIdentities,
                includeNonNTFS: true
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanning = false
                guard !self.isBusy, generation == self.scanGeneration else { return }

                if let scanResult {
                    self.allDisks = scanResult.disks
                    self.logging.recordScanReport(scanResult.report)
                    self.applyDiskFilter()

                    if triggerAutoMountIfNeeded && self.settings.autoMountNTFS && self.settings.defaultMountWritable {
                        self.evaluateAutoMountCandidates()
                    }
                } else {
                    self.statusSummary = "Cannot read disk information — retry Refresh"
                    self.logging.log("diskutil list -plist failed or returned unreadable data", level: .warning, category: "Scanner")
                }
            }
        }
    }

    /// Instantaneously updates the visible disk list based on the user's non-NTFS preference without slow diskutil rescans.
    func applyDiskFilter() {
        if settings.showNonNTFSVolumes {
            disks = allDisks
        } else {
            disks = allDisks.filter(\.isNTFS)
        }
        updateStatusSummary()

        if selectedDiskID == nil || !disks.contains(where: { $0.id == selectedDiskID }) {
            selectedDiskID = disks.first?.id
        }
    }

    /// Toggles showing non-NTFS external volumes with instant UI feedback.
    func toggleShowNonNTFS(_ show: Bool) {
        settings.showNonNTFSVolumes = show
        applyDiskFilter()
    }

    private func updateStatusSummary() {
        if disks.isEmpty {
            statusSummary = settings.showNonNTFSVolumes
                ? "No external drives connected"
                : "No external NTFS drives connected"
        } else {
            let ntfsCount = disks.filter(\.isNTFS).count
            let nonNTFSCount = disks.count - ntfsCount
            if nonNTFSCount > 0 {
                statusSummary = "\(ntfsCount) NTFS, \(nonNTFSCount) other volume(s) · \(writableCount) writable"
            } else {
                statusSummary = "\(disks.count) external NTFS volume(s) · \(writableCount) writable"
            }
        }
    }

    private func evaluateAutoMountCandidates() {
        guard !isBusy, backendEnvironment.isSelectedBackendReady else { return }
        for disk in disks where disk.isNTFS && disk.isReadOnly && disk.mediaIdentity != nil {
            guard let identity = disk.mediaIdentity, !autoMountedIdentities.contains(identity) else { continue }
            autoMountedIdentities.insert(identity)
            logging.log("Auto-mounting newly connected NTFS volume \(disk.name) (\(disk.deviceIdentifier))", level: .notice, category: "AutoMount")
            enableWriteAccess(for: disk)
            break
        }
    }

    // MARK: - Core Disk Operations

    func enableWriteAccess(for disk: DiskInfo) {
        guard !isBusy else { return }
        guard disk.isNTFS else {
            statusSummary = "\(disk.name) is not an NTFS volume"
            activeAlert = DashboardAlertItem(
                title: "Not an NTFS Volume",
                message: "\(disk.name) is formatted as \(disk.filesystemName). Read/Write mounting via ntfs-3g is only designed for NTFS partitions.",
                detailedLog: "Device: /dev/\(disk.deviceIdentifier)\nDetected Filesystem: \(disk.filesystemName) (\(disk.rawFilesystemType))",
                offerFullDiskAccess: false,
                offerInstallCheck: false
            )
            return
        }
        guard disk.mediaIdentity != nil else {
            activeAlert = DashboardAlertItem(
                title: "Hardware Identity Unavailable",
                message: "Could not verify the physical IOMedia registry identity for \(disk.name) (\(disk.deviceIdentifier)). Refresh the volume list and try again.",
                detailedLog: nil,
                offerFullDiskAccess: false,
                offerInstallCheck: false
            )
            return
        }

        isBusy = true
        scanGeneration += 1
        activeDeviceID = disk.deviceIdentifier
        activeTransactionStep = .validatingIdentity
        statusSummary = "Enabling write access for \(disk.name)…"

        let backend = settings.preferredBackend
        let requireBio = settings.requireBiometricConfirmation
        let openFinder = settings.openFinderAfterMount
        let auth = authService
        let mounter = mountService

        Task {
            if requireBio {
                statusSummary = "Waiting for Touch ID / authentication…"
                let confirmed = await auth.evaluateBiometricConfirmationIfAvailable(
                    reason: "enable NTFS read/write access for \(disk.name)"
                )
                if !confirmed {
                    self.isBusy = false
                    self.activeDeviceID = nil
                    self.activeTransactionStep = nil
                    self.statusSummary = "Authorization cancelled"
                    self.logging.log("Touch ID confirmation cancelled for \(disk.deviceIdentifier)", level: .notice, category: "Auth")
                    return
                }
            }

            // Pre-open current mount directory briefly as guoquan/mountfs does to ensure automounter state is settled
            if let existingMount = disk.mountPoint, let dir = opendir(existingMount) {
                closedir(dir)
            }

            let stepHandler: @Sendable (MountTransactionStep) -> Void = { step in
                Task { @MainActor in
                    self.activeTransactionStep = step
                    self.statusSummary = step.progressLabel
                }
            }

            let result: Result<MountOperationOutcome, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let outcome = try mounter.enableReadWrite(for: disk, backend: backend, onStepChange: stepHandler)
                    return .success(outcome)
                } catch {
                    return .failure(error)
                }
            }.value

            self.isBusy = false
            self.activeDeviceID = nil
            self.activeTransactionStep = nil

            switch result {
            case .success(let outcome):
                self.verifiedIdentities[outcome.device] = outcome.mediaIdentity
                self.logging.recordOperationOutput(outcome.operationLog)
                self.logging.log(
                    "Enabled Read/Write access for \(disk.name) (\(outcome.device)) at \(outcome.mountPoint)",
                    level: .notice,
                    category: "Mount",
                    details: outcome.operationLog
                )
                self.statusSummary = "Write access enabled for \(disk.name)"
                if openFinder {
                    NSWorkspace.shared.open(URL(fileURLWithPath: outcome.mountPoint))
                }
                self.postNotificationIfEnabled(
                    title: "NTFS Read/Write Enabled",
                    body: "\(disk.name) is now writable in Finder at \(outcome.mountPoint)."
                )
                self.refreshDisks()

            case .failure(let error):
                self.handleOperationError(error, for: disk, operationName: "Enable Write Access")
                self.refreshDisks()
            }
        }
    }

    func remountReadOnly(for disk: DiskInfo) {
        guard !isBusy else { return }
        isBusy = true
        scanGeneration += 1
        activeDeviceID = disk.deviceIdentifier
        activeTransactionStep = .recoveringReadOnly
        statusSummary = "Remounting \(disk.name) in safe read-only mode…"

        let mounter = mountService
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try mounter.remountReadOnly(for: disk))
                } catch {
                    return .failure(error)
                }
            }.value

            self.isBusy = false
            self.activeDeviceID = nil
            self.activeTransactionStep = nil

            switch result {
            case .success(let output):
                self.logging.recordOperationOutput(output)
                self.logging.log("Remounted \(disk.name) (\(disk.deviceIdentifier)) as Read-Only", level: .notice, category: "Mount", details: output)
                self.statusSummary = "\(disk.name) mounted Read-Only"
                self.refreshDisks()
            case .failure(let error):
                self.handleOperationError(error, for: disk, operationName: "Remount Read-Only")
                self.refreshDisks()
            }
        }
    }

    func unmount(for disk: DiskInfo) {
        guard !isBusy else { return }
        isBusy = true
        scanGeneration += 1
        activeDeviceID = disk.deviceIdentifier
        statusSummary = "Unmounting \(disk.name)…"

        let mounter = mountService
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try mounter.unmountVolume(for: disk))
                } catch {
                    return .failure(error)
                }
            }.value

            self.isBusy = false
            self.activeDeviceID = nil

            switch result {
            case .success(let output):
                self.logging.recordOperationOutput(output)
                self.logging.log("Unmounted \(disk.name) (\(disk.deviceIdentifier))", level: .notice, category: "Unmount", details: output)
                self.statusSummary = "Unmounted \(disk.name)"
                self.postNotificationIfEnabled(
                    title: "Volume Unmounted",
                    body: "\(disk.name) (\(disk.deviceIdentifier)) has been unmounted."
                )
                self.refreshDisks()
            case .failure(let error):
                self.handleOperationError(error, for: disk, operationName: "Unmount Volume")
                self.refreshDisks()
            }
        }
    }

    func safelyEject(for disk: DiskInfo) {
        guard !isBusy else { return }
        isBusy = true
        scanGeneration += 1
        activeDeviceID = disk.deviceIdentifier
        statusSummary = "Safely ejecting \(disk.name)…"

        let mounter = mountService
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try mounter.safelyEject(for: disk))
                } catch {
                    return .failure(error)
                }
            }.value

            self.isBusy = false
            self.activeDeviceID = nil

            switch result {
            case .success(let output):
                self.verifiedIdentities.removeValue(forKey: disk.deviceIdentifier)
                self.logging.recordOperationOutput(output)
                self.logging.log("Safely ejected \(disk.name) (\(disk.deviceIdentifier))", level: .notice, category: "Eject", details: output)
                self.statusSummary = "Safely ejected \(disk.name)"
                self.postNotificationIfEnabled(
                    title: "Safe to Disconnect",
                    body: "\(disk.name) has been safely ejected."
                )
                self.refreshDisks()
            case .failure(let error):
                self.handleOperationError(error, for: disk, operationName: "Safely Eject")
                self.refreshDisks()
            }
        }
    }

    func openInFinder(for disk: DiskInfo) {
        guard let mountPoint = disk.mountPoint, !mountPoint.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

    func openFullDiskAccess() {
        backendService.openFullDiskAccessSettings()
    }

    func generateInstallationDiagnosisReport() -> String {
        backendService.generateInstallationDiagnosis(selectedBackend: settings.preferredBackend)
    }

    func runInstallationCheckAndShowSheet() {
        refreshBackendStatus()
        auditSystemReadiness()
        let report = generateInstallationDiagnosisReport()
        logging.recordOperationOutput(report)
        logging.log("Completed NTFS driver & backend installation check", level: .info, category: "Diagnostics", details: report)
        diagnosticsSheetMode = .installation
        isShowingDiagnosticsSheet = true
    }

    func installDriversAutomatically() {
        guard !isInstallingDrivers else { return }

        if backendService.findHomebrewExecutable() == nil {
            installDriversInTerminal()
            return
        }

        isInstallingDrivers = true
        driverInstallProgressText = "Installing macFUSE & ntfs-3g-mac via Homebrew…"
        statusSummary = "Installing NTFS drivers via Homebrew…"
        let selected = settings.preferredBackend
        let service = backendService
        logging.log("Starting automatic NTFS driver installation for \(selected.displayName)", level: .notice, category: "Installer")

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                service.installMissingDrivers(selectedBackend: selected)
            }.value

            self.isInstallingDrivers = false
            self.driverInstallProgressText = nil
            self.refreshBackendStatus()
            self.auditSystemReadiness()

            switch result {
            case .success(let logOutput):
                self.logging.recordOperationOutput(logOutput)
                self.logging.log("Successfully installed NTFS drivers via Homebrew", level: .notice, category: "Installer", details: logOutput)
                self.statusSummary = self.backendEnvironment.isSelectedBackendReady
                    ? "NTFS drivers installed and ready"
                    : "Driver installation finished — verify status"
                self.postNotificationIfEnabled(
                    title: "NTFS Drivers Installed",
                    body: "macFUSE and ntfs-3g installation completed."
                )
            case .failure(let error):
                let details = error.localizedDescription
                self.logging.recordOperationOutput(details)
                self.logging.log("Automatic driver installation failed; offering Terminal fallback", level: .warning, category: "Installer", details: details)
                self.statusSummary = "Automatic install needs Terminal authorization"
                self.installDriversInTerminal()
            }
        }
    }

    func installDriversInTerminal() {
        let cmd = backendEnvironment.homebrewInstallCommand
        let scriptContent = """
        #!/bin/bash
        clear
        echo "======================================================"
        echo "  u-NTFS Automatic Driver Setup (macFUSE + ntfs-3g)"
        echo "======================================================"
        echo ""
        if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
            echo "Homebrew is not installed. Installing Homebrew first..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        echo "Running: \(cmd)"
        echo ""
        \(cmd)
        echo ""
        echo "======================================================"
        echo "  Setup finished! You can now return to u-NTFS"
        echo "  and click 'Refresh Driver Status'."
        echo "======================================================\n"
        """
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("u-ntfs-install-drivers.command")
        do {
            try scriptContent.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
            NSWorkspace.shared.open(tempURL)
            logging.log("Launched interactive driver installer in Terminal.app", level: .info, category: "Installer")
        } catch {
            logging.log("Failed to launch Terminal installer script: \(error.localizedDescription)", level: .error, category: "Installer")
        }
    }

    // MARK: - Error Handling & Notifications

    private func handleOperationError(_ error: Error, for disk: DiskInfo, operationName: String) {
        if let fsError = error as? NTFSFilesystemError, fsError == .authorizationCancelled {
            statusSummary = "Authorization cancelled"
            logging.log("\(operationName) cancelled by user for \(disk.deviceIdentifier)", level: .info, category: "Auth")
            return
        }

        let message = error.localizedDescription
        let diagnosis = generateInstallationDiagnosisReport()
        let fullDetails = """
        Operation: \(operationName)
        Target Volume: \(disk.name) (\(disk.deviceIdentifier))
        Media Identity: \(disk.mediaIdentity ?? "unavailable")
        Selected Backend: \(settings.preferredBackend.displayName)

        Error Details:
        \(message)

        --- Installation Diagnosis ---
        \(diagnosis)
        """

        logging.recordOperationOutput(fullDetails)
        logging.log("\(operationName) failed for \(disk.name): \(message)", level: .error, category: "Mount", details: fullDetails)
        statusSummary = "\(operationName) failed"

        let needsFDA = message.contains("Full Disk Access")
            || message.contains("Operation not permitted")
            || message.contains("Permission denied")
        let needsInstall = message.contains("ntfs-3g is not installed")
            || message.contains("macFUSE was not found")

        activeAlert = DashboardAlertItem(
            title: "\(operationName) Could Not Complete",
            message: message,
            detailedLog: fullDetails,
            offerFullDiskAccess: needsFDA,
            offerInstallCheck: needsInstall
        )
    }

    private func postNotificationIfEnabled(title: String, body: String) {
        guard settings.enableNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - CrystalDiskInfo Health & Telemetry Operations

    func health(for disk: DiskInfo) -> DiskHealthInfo? {
        diskHealthCache[disk.deviceIdentifier]
    }

    func fetchHealth(for disk: DiskInfo) {
        guard !isLoadingHealth else { return }
        isLoadingHealth = true
        let service = healthService

        Task {
            let info = await service.inspectHealth(for: disk)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.diskHealthCache[disk.deviceIdentifier] = info
                self.isLoadingHealth = false
            }
        }
    }

    func installSmartmontools() {
        guard !isInstallingSmartctl else { return }
        isInstallingSmartctl = true
        smartctlInstallProgress = "Starting smartmontools installation via Homebrew…"
        let service = healthService

        Task {
            do {
                _ = try await service.installSmartmontools { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.smartctlInstallProgress = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isInstallingSmartctl = false
                    self.smartctlInstallProgress = nil
                    if let disk = self.selectedDisk {
                        self.fetchHealth(for: disk)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isInstallingSmartctl = false
                    self.smartctlInstallProgress = nil
                    self.activeAlert = DashboardAlertItem(
                        title: "smartmontools Installation Failed",
                        message: error.localizedDescription,
                        detailedLog: (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String,
                        offerFullDiskAccess: false,
                        offerInstallCheck: false
                    )
                }
            }
        }
    }

    // MARK: - NTFS Disk Formatting Operations

    func formatDiskAsNTFS(
        disk: DiskInfo,
        volumeLabel: String,
        quickFormat: Bool,
        wholeDiskErase: Bool,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard !isFormattingDisk, !isBusy else { return }
        isFormattingDisk = true
        formatProgressText = "Preparing to format '\(disk.name)' as NTFS…"
        let service = formatService
        let targetLabel = volumeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "UNTFS" : volumeLabel

        logging.log("Starting NTFS format on /dev/\(disk.deviceIdentifier) (wholeDisk=\(wholeDiskErase), label=\(targetLabel))", level: .info, category: "Format")

        Task {
            let result = await service.formatAsNTFS(
                disk: disk,
                volumeLabel: targetLabel,
                quickFormat: quickFormat,
                wholeDiskErase: wholeDiskErase
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isFormattingDisk = false
                self.formatProgressText = nil

                switch result {
                case .success(let report):
                    self.logging.log("NTFS format succeeded: \(report)", level: .info, category: "Format")
                    self.statusSummary = "Successfully formatted as NTFS (\(targetLabel))"
                    self.postNotificationIfEnabled(
                        title: "Format Complete",
                        body: "Volume '\(targetLabel)' was successfully formatted as NTFS."
                    )
                    self.refreshDisks()
                    completion?(true)

                case .failure(let error):
                    let message = error.localizedDescription
                    self.logging.log("NTFS format failed for \(disk.name): \(message)", level: .error, category: "Format")
                    self.activeAlert = DashboardAlertItem(
                        title: "NTFS Formatting Failed",
                        message: message,
                        detailedLog: (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String,
                        offerFullDiskAccess: message.contains("Operation not permitted") || message.contains("Permission denied"),
                        offerInstallCheck: message.contains("mkntfs")
                    )
                    completion?(false)
                }
            }
        }
    }

    // MARK: - System Readiness & Permissions Audit Operations

    func auditSystemReadiness() {
        readinessItems = readinessService.performAudit(selectedBackend: settings.preferredBackend)
    }

    func handleReadinessAction(_ actionType: ReadinessActionType) {
        switch actionType {
        case .openPrivacySecurity:
            readinessService.openPrivacySecurity()
        case .openFullDiskAccess:
            readinessService.openFullDiskAccess()
        case .installDrivers:
            installDriversAutomatically()
        case .installFuseT:
            installFuseTInTerminal()
        case .switchToFuseT:
            settings.preferredBackend = .fuseT
            refreshBackendStatus()
            auditSystemReadiness()
        case .refresh:
            refreshBackendStatus()
            auditSystemReadiness()
        }
    }

    func installFuseTInTerminal() {
        let script = "brew install --cask mac-fuse-t/homebrew-cask/fuse-t && brew install gromgit/fuse/ntfs-3g-mac"
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(script)"
        end tell
        """
        if let scriptObj = NSAppleScript(source: appleScript) {
            var errorInfo: NSDictionary?
            scriptObj.executeAndReturnError(&errorInfo)
        }
    }
}
