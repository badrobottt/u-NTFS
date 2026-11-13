import Foundation

/// Health grade inspired by CrystalDiskInfo disk status indicators.
enum HealthGrade: Sendable, Equatable, Hashable {
    case good(percentage: Int?)
    case caution(reason: String)
    case bad(reason: String)
    case notSupported
    case unknown

    var title: String {
        switch self {
        case .good(let pct):
            if let pct {
                return "GOOD \(pct)%"
            }
            return "GOOD"
        case .caution:
            return "CAUTION"
        case .bad:
            return "BAD"
        case .notSupported:
            return "NOT SUPPORTED"
        case .unknown:
            return "UNKNOWN"
        }
    }

    var isGood: Bool {
        if case .good = self { return true }
        return false
    }
}

/// Temperature status grade inspired by CrystalDiskInfo.
enum TemperatureGrade: Sendable, Equatable, Hashable {
    case normal(celsius: Int)
    case warm(celsius: Int)
    case critical(celsius: Int)
    case unavailable

    var celsius: Int? {
        switch self {
        case .normal(let c), .warm(let c), .critical(let c):
            return c
        case .unavailable:
            return nil
        }
    }

    var fahrenheit: Int? {
        guard let celsius else { return nil }
        return Int(Double(celsius) * 9.0 / 5.0 + 32.0)
    }

    var displayString: String {
        guard let c = celsius else { return "N/A" }
        if let f = fahrenheit {
            return "\(c) °C (\(f) °F)"
        }
        return "\(c) °C"
    }
}

/// Physical media category.
enum DiskMediaType: String, Sendable, Equatable, Hashable {
    case ssd = "Solid State Drive (SSD)"
    case hdd = "Hard Disk Drive (Rotational)"
    case flash = "Flash Memory / USB Drive"
    case unknown = "Unknown Media"
}

/// Individual S.M.A.R.T. attribute entry (ATA or NVMe metric).
struct SMARTAttribute: Identifiable, Sendable, Equatable, Hashable {
    let id: Int
    let name: String
    let current: Int?
    let worst: Int?
    let threshold: Int?
    let rawValue: String
    let isFailing: Bool

    var idHex: String {
        String(format: "%02X", id)
    }

    init(
        id: Int,
        name: String,
        current: Int? = nil,
        worst: Int? = nil,
        threshold: Int? = nil,
        rawValue: String,
        isFailing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.current = current
        self.worst = worst
        self.threshold = threshold
        self.rawValue = rawValue
        self.isFailing = isFailing
    }
}

/// Comprehensive hardware health and telemetry model inspired by CrystalDiskInfo.
struct DiskHealthInfo: Identifiable, Sendable, Equatable, Hashable {
    let deviceIdentifier: String
    let parentWholeDisk: String
    let modelName: String
    let serialNumber: String?
    let firmwareRevision: String?
    let mediaType: DiskMediaType
    let busProtocol: String?
    let totalSizeBytes: Int64
    let sectorSize: Int?
    let partitionScheme: String?
    let smartStatusDescription: String
    let healthGrade: HealthGrade
    let temperature: TemperatureGrade
    let powerOnHours: Int?
    let powerCycleCount: Int?
    let unsafeShutdowns: Int?
    let percentageUsed: Int?
    let totalBytesRead: Int64?
    let totalBytesWritten: Int64?
    let isSmartSupported: Bool
    let isSmartctlInstalled: Bool
    let attributes: [SMARTAttribute]
    let rawOutput: String?

    var id: String { deviceIdentifier }

    var formattedPowerOnTime: String? {
        guard let hours = powerOnHours else { return nil }
        if hours < 24 {
            return "\(hours) Hours"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return "\(days)d \(remainingHours)h (\(hours)h)"
    }

    var formattedHostReads: String? {
        guard let bytes = totalBytesRead, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var formattedHostWrites: String? {
        guard let bytes = totalBytesWritten, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    init(
        deviceIdentifier: String,
        parentWholeDisk: String,
        modelName: String,
        serialNumber: String?,
        firmwareRevision: String?,
        mediaType: DiskMediaType,
        busProtocol: String?,
        totalSizeBytes: Int64,
        sectorSize: Int?,
        partitionScheme: String?,
        smartStatusDescription: String,
        healthGrade: HealthGrade,
        temperature: TemperatureGrade,
        powerOnHours: Int?,
        powerCycleCount: Int?,
        unsafeShutdowns: Int?,
        percentageUsed: Int?,
        totalBytesRead: Int64?,
        totalBytesWritten: Int64?,
        isSmartSupported: Bool,
        isSmartctlInstalled: Bool,
        attributes: [SMARTAttribute],
        rawOutput: String? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.parentWholeDisk = parentWholeDisk
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.mediaType = mediaType
        self.busProtocol = busProtocol
        self.totalSizeBytes = totalSizeBytes
        self.sectorSize = sectorSize
        self.partitionScheme = partitionScheme
        self.smartStatusDescription = smartStatusDescription
        self.healthGrade = healthGrade
        self.temperature = temperature
        self.powerOnHours = powerOnHours
        self.powerCycleCount = powerCycleCount
        self.unsafeShutdowns = unsafeShutdowns
        self.percentageUsed = percentageUsed
        self.totalBytesRead = totalBytesRead
        self.totalBytesWritten = totalBytesWritten
        self.isSmartSupported = isSmartSupported
        self.isSmartctlInstalled = isSmartctlInstalled
        self.attributes = attributes
        self.rawOutput = rawOutput
    }
}
