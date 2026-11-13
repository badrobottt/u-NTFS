import SwiftUI
import AppKit

/// Visual badge indicating Read/Write, Read-Only, or Unmounted state.
struct MountStateBadge: View {
    let state: MountState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(state.title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: Capsule())
    }

    private var iconName: String {
        switch state {
        case .mountedWritable:
            return "checkmark.circle.fill"
        case .mountedReadOnly:
            return "lock.fill"
        case .unmounted:
            return "eject.circle"
        case .transitioning:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .mountedWritable:
            return .green
        case .mountedReadOnly:
            return .orange
        case .unmounted:
            return .secondary
        case .transitioning:
            return .blue
        case .error:
            return .red
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.14)
    }
}

/// Visual storage capacity gauge showing used, free, and total disk space.
struct StorageCapacityCard: View {
    let disk: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Storage Capacity", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text("\(Int((disk.usageFraction * 100).rounded()))% Used")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 12)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(barGradient)
                        .frame(width: max(8, geo.size.width * disk.usageFraction), height: 12)
                }
            }
            .frame(height: 12)

            HStack(spacing: 20) {
                capacityStat(title: "Total", value: disk.formattedTotalCapacity, color: .primary)
                Divider().frame(height: 24)
                capacityStat(title: "Used", value: disk.formattedUsedCapacity, color: disk.usageFraction > 0.9 ? .orange : .blue)
                Divider().frame(height: 24)
                capacityStat(title: "Available", value: disk.formattedAvailableCapacity, color: .green)
                Spacer()
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var barGradient: LinearGradient {
        if disk.usageFraction > 0.9 {
            return LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
        }
        if disk.isWritable {
            return LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
    }

    private func capacityStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

/// Live step-by-step progress banner during a mount/unmount/eject operation.
struct TransactionProgressBanner: View {
    let statusText: String
    let activeStep: MountTransactionStep?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                if let activeStep {
                    Text("mouNTFS transactional safety guard active (\(activeStep.rawValue)/4) — IOKit media identity pinned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Banner displaying driver readiness (`ntfs-3g` + `macFUSE` / `FSKit`) and quick setup actions.
struct BackendReadinessCard: View {
    let status: BackendEnvironmentStatus
    let isInstallingDrivers: Bool
    let installProgressText: String?
    let onInstallDrivers: () -> Void
    let onInstallInTerminal: () -> Void
    let onCheckInstallation: () -> Void
    let onOpenFullDiskAccess: () -> Void

    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isInstallingDrivers {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.isSelectedBackendReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isSelectedBackendReady ? .green : .orange)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isInstallingDrivers ? "Installing NTFS Drivers…" : (status.isSelectedBackendReady ? "NTFS Read/Write Engine Ready" : "NTFS Driver Setup Required"))
                        .font(.subheadline.weight(.semibold))
                    Text(installProgressText ?? status.readinessDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !status.isSelectedBackendReady {
                    Button(action: onInstallDrivers) {
                        Label(isInstallingDrivers ? "Installing…" : "Install Drivers", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isInstallingDrivers)
                }

                Button("Check Installation", action: onCheckInstallation)
                    .controlSize(.small)
                    .disabled(isInstallingDrivers)

                Button("Full Disk Access", action: onOpenFullDiskAccess)
                    .controlSize(.small)
            }

            if !status.isSelectedBackendReady {
                HStack(spacing: 8) {
                    Text(status.homebrewInstallCommand)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status.homebrewInstallCommand, forType: .string)
                        copiedCommand = true
                    } label: {
                        Label(copiedCommand ? "Copied" : "Copy Command", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)

                    Button(action: onInstallInTerminal) {
                        Label("Install in Terminal", systemImage: "terminal")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            (status.isSelectedBackendReady ? Color.green : Color.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// Modal sheet displaying diagnostic logs, installation checks, and disk scan reports.
struct DiagnosticsSheetView: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("u-NTFS Diagnostics & Reports")
                        .font(.headline)
                    Text("Read-only disk scan, driver verification, and transactional mount logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Section", selection: $viewModel.diagnosticsSheetMode) {
                    ForEach(DashboardViewModel.DiagnosticsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(16)

            Divider()

            Group {
                switch viewModel.diagnosticsSheetMode {
                case .logs:
                    logsListView
                case .installation:
                    monospacedReportView(viewModel.generateInstallationDiagnosisReport())
                case .scanReport:
                    monospacedReportView(viewModel.logging.lastScanReport)
                case .selfTests:
                    selfTestsListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Open Full Disk Access") {
                    viewModel.openFullDiskAccess()
                }

                if viewModel.diagnosticsSheetMode == .logs {
                    Button("Clear Logs") {
                        viewModel.logging.clearLogs()
                    }
                }

                Spacer()

                Button {
                    let textToCopy: String
                    switch viewModel.diagnosticsSheetMode {
                    case .logs:
                        textToCopy = viewModel.logging.exportFormattedReport()
                    case .installation:
                        textToCopy = viewModel.generateInstallationDiagnosisReport()
                    case .scanReport:
                        textToCopy = viewModel.logging.lastScanReport
                    case .selfTests:
                        textToCopy = MountFSSelfTests.runAllTests()
                            .map { "[\($0.passed ? "PASS" : "FAIL")] \($0.name): \($0.details)" }
                            .joined(separator: "\n")
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToCopy, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied Report" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    private var selfTestsListView: some View {
        let results = MountFSSelfTests.runAllTests()
        return List(results) { item in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(item.passed ? .green : .red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text(item.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.passed ? "PASS" : "FAIL")
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(item.passed ? .green : .red)
            }
            .padding(.vertical, 4)
        }
    }

    private var logsListView: some View {
        Group {
            if viewModel.logging.entries.isEmpty {
                ContentUnavailableView(
                    "No Activity Logs Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Mount, unmount, or refresh volumes to record diagnostic events.")
                )
            } else {
                List(viewModel.logging.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.rawValue)
                                .font(.caption2.weight(.bold).monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(levelColor(entry.level).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(levelColor(entry.level))

                            Text(entry.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)

                        if let details = entry.details, !details.isEmpty {
                            Text(details)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func monospacedReportView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func levelColor(_ level: DiagnosticLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .notice: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
