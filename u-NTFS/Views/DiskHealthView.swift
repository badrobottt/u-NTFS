import SwiftUI

/// CrystalDiskInfo-inspired disk health, temperature, and SMART telemetry view.
struct DiskHealthView: View {
    let health: DiskHealthInfo
    let isLoading: Bool
    let onRefresh: () -> Void
    let onInstallSmartctl: () -> Void
    let isInstallingSmartctl: Bool
    let installProgressText: String?

    init(
        health: DiskHealthInfo,
        isLoading: Bool = false,
        onRefresh: @escaping () -> Void,
        onInstallSmartctl: @escaping () -> Void,
        isInstallingSmartctl: Bool = false,
        installProgressText: String? = nil
    ) {
        self.health = health
        self.isLoading = isLoading
        self.onRefresh = onRefresh
        self.onInstallSmartctl = onInstallSmartctl
        self.isInstallingSmartctl = isInstallingSmartctl
        self.installProgressText = installProgressText
    }

    var body: some View {
        VStack(spacing: 16) {
            // Top Section: CrystalDiskInfo Badges & Primary Specs
            HStack(alignment: .top, spacing: 14) {
                // CrystalDiskInfo Health Badge
                healthStatusBadge
                    .frame(width: 170)

                // CrystalDiskInfo Temperature Badge
                temperatureBadge
                    .frame(width: 150)

                // Drive Hardware Specification Grid
                hardwareSpecsCard
            }

            // smartmontools recommendation banner if smartctl is not available
            if !health.isSmartctlInstalled {
                smartmontoolsPromptCard
            }

            // S.M.A.R.T. Attributes Table
            smartAttributesSection
        }
    }

    // MARK: - Health Status Badge (CrystalDiskInfo Style)

    private var healthStatusBadge: some View {
        VStack(spacing: 6) {
            Text("HEALTH STATUS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(healthBadgeForeground.opacity(0.85))

            Spacer(minLength: 4)

            Image(systemName: healthBadgeIcon)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(healthBadgeForeground)

            Text(health.healthGrade.title)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(healthBadgeForeground)
                .multilineTextAlignment(.center)

            Spacer(minLength: 4)

            Text(health.smartStatusDescription)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(healthBadgeForeground.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(height: 145)
        .frame(maxWidth: .infinity)
        .background(healthBadgeBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(healthBadgeForeground.opacity(0.3), lineWidth: 1.5)
        )
    }

    private var healthBadgeForeground: Color {
        switch health.healthGrade {
        case .good:
            return Color.white
        case .caution:
            return Color.black
        case .bad:
            return Color.white
        case .notSupported, .unknown:
            return Color.primary
        }
    }

    private var healthBadgeBackground: Color {
        switch health.healthGrade {
        case .good:
            return Color.blue
        case .caution:
            return Color.yellow
        case .bad:
            return Color.red
        case .notSupported, .unknown:
            return Color.secondary.opacity(0.18)
        }
    }

    private var healthBadgeIcon: String {
        switch health.healthGrade {
        case .good:
            return "checkmark.shield.fill"
        case .caution:
            return "exclamationmark.shield.fill"
        case .bad:
            return "xmark.shield.fill"
        case .notSupported, .unknown:
            return "questionmark.shield"
        }
    }

    // MARK: - Temperature Badge (CrystalDiskInfo Style)

    private var temperatureBadge: some View {
        VStack(spacing: 6) {
            Text("TEMPERATURE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(temperatureForeground.opacity(0.85))

            Spacer(minLength: 4)

            Image(systemName: "thermometer.medium")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(temperatureForeground)

            if let c = health.temperature.celsius {
                Text("\(c) °C")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(temperatureForeground)

                if let f = health.temperature.fahrenheit {
                    Text("\(f) °F")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(temperatureForeground.opacity(0.85))
                }
            } else {
                Text("N/A")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(temperatureForeground)

                Text("Sensor Offline")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(temperatureForeground.opacity(0.75))
            }

            Spacer(minLength: 4)

            Text(temperatureStatusSubtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(temperatureForeground.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(height: 145)
        .frame(maxWidth: .infinity)
        .background(temperatureBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(temperatureForeground.opacity(0.3), lineWidth: 1.5)
        )
    }

    private var temperatureForeground: Color {
        switch health.temperature {
        case .normal:
            return Color.white
        case .warm:
            return Color.black
        case .critical:
            return Color.white
        case .unavailable:
            return Color.primary
        }
    }

    private var temperatureBackground: Color {
        switch health.temperature {
        case .normal:
            return Color.teal
        case .warm:
            return Color.orange
        case .critical:
            return Color.red
        case .unavailable:
            return Color.secondary.opacity(0.18)
        }
    }

    private var temperatureStatusSubtitle: String {
        switch health.temperature {
        case .normal:
            return "Normal (<45°C)"
        case .warm:
            return "Warm (45-54°C)"
        case .critical:
            return "Overheating (≥55°C)"
        case .unavailable:
            return "Requires smartctl"
        }
    }

    // MARK: - Hardware Specification Grid

    private var hardwareSpecsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(health.modelName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh health and temperature data")
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                specItem(label: "Firmware", value: health.firmwareRevision ?? "—")
                specItem(label: "Serial Number", value: health.serialNumber ?? "—")
                specItem(label: "Interface", value: health.busProtocol ?? "—")
                specItem(label: "Media Type", value: health.mediaType.rawValue)
                specItem(label: "Sector Size", value: health.sectorSize.map { "\($0) Bytes" } ?? "512 B")
                specItem(label: "Parent Disk", value: "/dev/\(health.parentWholeDisk)")

                if let pot = health.formattedPowerOnTime {
                    specItem(label: "Power On Hours", value: pot)
                }
                if let cycles = health.powerCycleCount {
                    specItem(label: "Power Cycles", value: "\(cycles) times")
                }
                if let writes = health.formattedHostWrites {
                    specItem(label: "Host Writes", value: writes)
                }
                if let reads = health.formattedHostReads {
                    specItem(label: "Host Reads", value: reads)
                }
            }
        }
        .padding(12)
        .frame(height: 145)
        .frame(maxWidth: .infinity)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func specItem(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 85, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - smartmontools Prompt Banner

    private var smartmontoolsPromptCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Live Temperature & Deep S.M.A.R.T. Telemetry")
                    .font(.subheadline.weight(.semibold))
                Text("Install `smartmontools` via Homebrew for real-time Celsius temperature readings, NVMe wear percentage, and full attribute monitoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstallingSmartctl {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(installProgressText ?? "Installing…")
                        .font(.caption)
                }
            } else {
                Button("Install smartctl") {
                    onInstallSmartctl()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - S.M.A.R.T. Attributes Table

    private var smartAttributesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("S.M.A.R.T. Attributes", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(health.attributes.count) attribute(s) monitored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if health.attributes.isEmpty {
                VStack(spacing: 6) {
                    Text("No individual S.M.A.R.T. attribute records reported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Standard USB flash drives do not expose SMART registers. For external SSDs/HDDs, install smartmontools above.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.background.secondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    HStack {
                        Text("ID").frame(width: 45, alignment: .leading)
                        Text("Attribute Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Current").frame(width: 60, alignment: .trailing)
                        Text("Worst").frame(width: 60, alignment: .trailing)
                        Text("Threshold").frame(width: 65, alignment: .trailing)
                        Text("Raw Value").frame(width: 100, alignment: .trailing)
                        Text("Status").frame(width: 55, alignment: .center)
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.background.secondary.opacity(0.8))

                    Divider()

                    ForEach(health.attributes) { attr in
                        HStack {
                            Text(attr.idHex)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 45, alignment: .leading)

                            Text(attr.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(attr.current.map { "\($0)" } ?? "—")
                                .font(.caption2.monospaced())
                                .frame(width: 60, alignment: .trailing)

                            Text(attr.worst.map { "\($0)" } ?? "—")
                                .font(.caption2.monospaced())
                                .frame(width: 60, alignment: .trailing)

                            Text(attr.threshold.map { "\($0)" } ?? "—")
                                .font(.caption2.monospaced())
                                .frame(width: 65, alignment: .trailing)

                            Text(attr.rawValue)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .frame(width: 100, alignment: .trailing)

                            Circle()
                                .fill(attr.isFailing ? Color.red : Color.green)
                                .frame(width: 8, height: 8)
                                .frame(width: 55, alignment: .center)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)

                        Divider()
                    }
                }
                .background(.background.secondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }
}
