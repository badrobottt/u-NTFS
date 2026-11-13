import Foundation

/// Protocol for querying physical disk health, live temperature, and SMART attributes.
protocol DiskHealthServicing: Sendable {
    nonisolated func inspectHealth(for disk: DiskInfo) async -> DiskHealthInfo
    nonisolated func isSmartctlAvailable() -> Bool
    nonisolated func installSmartmontools(onOutput: @Sendable @escaping (String) -> Void) async throws -> String
}

/// Service implementing multi-tier telemetry (macOS IOKit + diskutil + smartctl JSON).
final class DiskHealthService: DiskHealthServicing, @unchecked Sendable {
    static let shared = DiskHealthService()

    init() {}

    // MARK: - Executable Discovery

    nonisolated func findSmartctlExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/smartctl",
            "/usr/local/bin/smartctl",
            "/usr/bin/smartctl"
        ]
        let fileManager = FileManager.default
        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    nonisolated func isSmartctlAvailable() -> Bool {
        findSmartctlExecutable() != nil
    }

    // MARK: - Health Inspection

    nonisolated func inspectHealth(for disk: DiskInfo) async -> DiskHealthInfo {
        let parentDisk = disk.parentWholeDisk.isEmpty ? disk.deviceIdentifier : disk.parentWholeDisk
        let smartctlPath = findSmartctlExecutable()

        // Tier 1: Try smartctl JSON if available
        if let smartctlPath {
            if let smartInfo = runSmartctlJSON(path: smartctlPath, parentDisk: parentDisk, disk: disk) {
                return smartInfo
            }
        }

        // Tier 2: macOS Native fallback (diskutil plist + ioreg block storage)
        return inspectHealthViaMacOSNative(parentDisk: parentDisk, disk: disk, smartctlAvailable: smartctlPath != nil)
    }

    // MARK: - Tier 1: smartctl JSON Engine

    private nonisolated func runSmartctlJSON(path: String, parentDisk: String, disk: DiskInfo) -> DiskHealthInfo? {
        let devicePath = "/dev/\(parentDisk)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // smartctl returns non-zero exit codes for warnings, so we read stdout regardless of exit code
        process.arguments = ["-a", "-j", devicePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return parseSmartctlJSON(json, parentDisk: parentDisk, disk: disk, rawOutput: String(data: data, encoding: .utf8))
        } catch {
            return nil
        }
    }

    private nonisolated func parseSmartctlJSON(
        _ json: [String: Any],
        parentDisk: String,
        disk: DiskInfo,
        rawOutput: String?
    ) -> DiskHealthInfo {
        let modelName = (json["model_name"] as? String)
            ?? (json["device"] as? [String: Any])?["name"] as? String
            ?? disk.deviceModel
        let serialNumber = json["serial_number"] as? String
        let firmware = json["firmware_version"] as? String

        // Temperature extraction
        var detectedTemp: Int?
        if let tempDict = json["temperature"] as? [String: Any],
           let current = tempDict["current"] as? Int {
            detectedTemp = current
        }

        // SMART status & Health Grade
        let smartStatusDict = json["smart_status"] as? [String: Any]
        let passed = smartStatusDict?["passed"] as? Bool

        // NVMe specific log
        let nvmeLog = json["nvme_smart_health_information_log"] as? [String: Any]
        var powerOnHours: Int?
        var powerCycles: Int?
        var unsafeShutdowns: Int?
        var percentageUsed: Int?
        var hostReadsBytes: Int64?
        var hostWritesBytes: Int64?

        if let nvme = nvmeLog {
            if detectedTemp == nil, let nvmeTemp = nvme["temperature"] as? Int {
                detectedTemp = nvmeTemp
            }
            if let used = nvme["percentage_used"] as? Int {
                percentageUsed = used
            }
            if let hours = nvme["power_on_hours"] as? Int {
                powerOnHours = hours
            }
            if let cycles = nvme["power_cycles"] as? Int {
                powerCycles = cycles
            }
            if let shutdowns = nvme["unsafe_shutdowns"] as? Int {
                unsafeShutdowns = shutdowns
            }
            // Data units read/written in NVMe SMART log are units of 1,000 sectors of 512 bytes (approx 512,000 bytes)
            if let unitsRead = nvme["data_units_read"] as? Int64 {
                hostReadsBytes = unitsRead * 512000
            }
            if let unitsWritten = nvme["data_units_written"] as? Int64 {
                hostWritesBytes = unitsWritten * 512000
            }
        }

        // ATA power on time
        if powerOnHours == nil,
           let potDict = json["power_on_time"] as? [String: Any],
           let hours = potDict["hours"] as? Int {
            powerOnHours = hours
        }

        if powerCycles == nil,
           let pcDict = json["power_cycle_count"] as? Int {
            powerCycles = pcDict
        }

        // Attributes extraction
        var attributes: [SMARTAttribute] = []
        if let ataTable = (json["ata_smart_attributes"] as? [String: Any])?["table"] as? [[String: Any]] {
            for row in ataTable {
                if let id = row["id"] as? Int,
                   let name = row["name"] as? String {
                    let current = row["value"] as? Int
                    let worst = row["worst"] as? Int
                    let thresh = row["thresh"] as? Int
                    let rawDict = row["raw"] as? [String: Any]
                    let rawStr = (rawDict?["string"] as? String) ?? "\(rawDict?["value"] ?? "")"
                    let failing = (row["when_failed"] as? String)?.isEmpty == false

                    if detectedTemp == nil && (id == 194 || id == 231 || name.lowercased().contains("temperature")) {
                        if let t = rawDict?["value"] as? Int, t > 0, t < 120 {
                            detectedTemp = t
                        }
                    }

                    attributes.append(SMARTAttribute(
                        id: id,
                        name: name,
                        current: current,
                        worst: worst,
                        threshold: thresh,
                        rawValue: rawStr,
                        isFailing: failing
                    ))
                }
            }
        }

        // Temperature grade
        let tempGrade: TemperatureGrade
        if let detectedTemp {
            if detectedTemp >= 55 {
                tempGrade = .critical(celsius: detectedTemp)
            } else if detectedTemp >= 45 {
                tempGrade = .warm(celsius: detectedTemp)
            } else {
                tempGrade = .normal(celsius: detectedTemp)
            }
        } else {
            tempGrade = .unavailable
        }

        // Overall Health Grade
        let healthGrade: HealthGrade
        if let passed {
            if passed {
                if let percentageUsed {
                    let lifeRemaining = max(0, 100 - percentageUsed)
                    healthGrade = .good(percentage: lifeRemaining)
                } else {
                    healthGrade = .good(percentage: 100)
                }
            } else {
                healthGrade = .bad(reason: "SMART overall health self-assessment test: FAILED")
            }
        } else {
            healthGrade = .unknown
        }

        // Determine media type
        let rotationRate = json["rotation_rate"] as? Int
        let mediaType: DiskMediaType
        if rotationRate == 0 || nvmeLog != nil {
            mediaType = .ssd
        } else if let rate = rotationRate, rate > 0 {
            mediaType = .hdd
        } else {
            mediaType = disk.isInternal ? .ssd : .flash
        }

        return DiskHealthInfo(
            deviceIdentifier: disk.deviceIdentifier,
            parentWholeDisk: parentDisk,
            modelName: modelName.isEmpty ? disk.name : modelName,
            serialNumber: serialNumber,
            firmwareRevision: firmware,
            mediaType: mediaType,
            busProtocol: (json["device"] as? [String: Any])?["protocol"] as? String ?? disk.connectionType,
            totalSizeBytes: disk.totalCapacityBytes,
            sectorSize: (json["logical_block_size"] as? Int) ?? 512,
            partitionScheme: nil,
            smartStatusDescription: passed == true ? "PASSED (smartctl verified)" : (passed == false ? "FAILED" : "Active"),
            healthGrade: healthGrade,
            temperature: tempGrade,
            powerOnHours: powerOnHours,
            powerCycleCount: powerCycles,
            unsafeShutdowns: unsafeShutdowns,
            percentageUsed: percentageUsed,
            totalBytesRead: hostReadsBytes,
            totalBytesWritten: hostWritesBytes,
            isSmartSupported: true,
            isSmartctlInstalled: true,
            attributes: attributes,
            rawOutput: rawOutput
        )
    }

    // MARK: - Tier 2: macOS Native Fallback Engine

    private nonisolated func inspectHealthViaMacOSNative(
        parentDisk: String,
        disk: DiskInfo,
        smartctlAvailable: Bool
    ) -> DiskHealthInfo {
        let parentInfo = readDiskutilPlist(device: parentDisk) ?? [:]
        let partitionInfo = readDiskutilPlist(device: disk.deviceIdentifier) ?? [:]

        let smartStatus = (parentInfo["SMARTStatus"] as? String)
            ?? (partitionInfo["SMARTStatus"] as? String)
            ?? disk.smartStatus
            ?? "Not Supported"

        let isSolidState = (parentInfo["SolidState"] as? Bool) ?? (partitionInfo["SolidState"] as? Bool) ?? false
        let busProtocol = (parentInfo["BusProtocol"] as? String)
            ?? (partitionInfo["BusProtocol"] as? String)
            ?? disk.connectionType
        let mediaName = (parentInfo["MediaName"] as? String)
            ?? (parentInfo["IORegistryEntryName"] as? String)
            ?? disk.deviceModel
        let sectorSize = (parentInfo["DeviceBlockSize"] as? Int) ?? 512
        let partitionScheme = parentInfo["Content"] as? String

        // Query IOKit Registry for Serial Number & Firmware
        let ioregData = queryIORegistryBlockDevice(for: parentDisk)

        let modelName = ioregData.productName ?? mediaName
        let serialNumber = ioregData.serialNumber
        let firmware = ioregData.firmwareRevision

        let mediaType: DiskMediaType
        if isSolidState {
            mediaType = .ssd
        } else if busProtocol.lowercased() == "usb" && (parentInfo["RemovableMedia"] as? Bool == true) {
            mediaType = .flash
        } else {
            mediaType = .hdd
        }

        let isSmartSupported = !smartStatus.lowercased().contains("not supported")

        let healthGrade: HealthGrade
        if smartStatus.lowercased() == "verified" {
            healthGrade = .good(percentage: 100)
        } else if smartStatus.lowercased() == "failing" {
            healthGrade = .bad(reason: "macOS S.M.A.R.T. subsystem reports drive status as FAILING")
        } else if !isSmartSupported {
            healthGrade = .notSupported
        } else {
            healthGrade = .unknown
        }

        var attributes: [SMARTAttribute] = []
        if isSmartSupported {
            attributes.append(SMARTAttribute(
                id: 0,
                name: "macOS Core SMART Health Verification",
                current: 100,
                worst: 100,
                threshold: 50,
                rawValue: smartStatus,
                isFailing: smartStatus.lowercased() == "failing"
            ))
        }

        return DiskHealthInfo(
            deviceIdentifier: disk.deviceIdentifier,
            parentWholeDisk: parentDisk,
            modelName: modelName.isEmpty ? disk.name : modelName,
            serialNumber: serialNumber,
            firmwareRevision: firmware,
            mediaType: mediaType,
            busProtocol: busProtocol,
            totalSizeBytes: disk.totalCapacityBytes,
            sectorSize: sectorSize,
            partitionScheme: partitionScheme,
            smartStatusDescription: smartStatus,
            healthGrade: healthGrade,
            temperature: .unavailable,
            powerOnHours: nil,
            powerCycleCount: nil,
            unsafeShutdowns: nil,
            percentageUsed: nil,
            totalBytesRead: nil,
            totalBytesWritten: nil,
            isSmartSupported: isSmartSupported,
            isSmartctlInstalled: smartctlAvailable,
            attributes: attributes,
            rawOutput: nil
        )
    }

    private nonisolated func readDiskutilPlist(device: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", device]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        } catch {
            return nil
        }
    }

    private nonisolated func queryIORegistryBlockDevice(for parentDisk: String) -> (productName: String?, serialNumber: String?, firmwareRevision: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-arc", "IOBlockStorageDevice"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard !data.isEmpty,
                  let array = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
                return (nil, nil, nil)
            }

            for entry in array {
                if let devChars = entry["Device Characteristics"] as? [String: Any] {
                    let serial = devChars["Serial Number"] as? String
                    let product = devChars["Product Name"] as? String
                    let rev = devChars["Product Revision Level"] as? String
                    if serial != nil || product != nil || rev != nil {
                        return (product, serial, rev)
                    }
                }
            }
        } catch {
            return (nil, nil, nil)
        }
        return (nil, nil, nil)
    }

    // MARK: - smartmontools Automated Installer

    nonisolated func installSmartmontools(onOutput: @Sendable @escaping (String) -> Void) async throws -> String {
        let brewPath = findHomebrewPath()
        guard let brew = brewPath else {
            throw NSError(
                domain: "u-NTFS.DiskHealthService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Homebrew executable not found. Please install Homebrew from https://brew.sh first."]
            )
        }

        onOutput("Found Homebrew at \(brew)… Running 'brew install smartmontools'…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "smartmontools"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let reader = pipe.fileHandleForReading
        var collectedLogs = ""

        try process.run()

        let data = reader.readDataToEndOfFile()
        process.waitUntilExit()

        if let text = String(data: data, encoding: .utf8) {
            collectedLogs += text
            onOutput(text)
        }

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "u-NTFS.DiskHealthService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to install smartmontools:\n\(collectedLogs)"]
            )
        }

        onOutput("smartmontools installed successfully!")
        return collectedLogs
    }

    private nonisolated func findHomebrewPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
