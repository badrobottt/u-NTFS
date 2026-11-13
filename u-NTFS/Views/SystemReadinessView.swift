import SwiftUI

/// Modern System Readiness and Permissions checklist view.
/// Shows real-time installation and authorization status for macOS drivers, system extensions, and permissions.
struct SystemReadinessView: View {
    @Bindable var viewModel: DashboardViewModel
    var isPresentedAsSheet: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCommand: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBanner
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    engineSummaryCard

                    ForEach(ReadinessCategory.allCases) { category in
                        let items = viewModel.readinessItems.filter { $0.category == category }
                        if !items.isEmpty {
                            categorySection(category: category, items: items)
                        }
                    }
                }
                .padding(20)
            }

            if isPresentedAsSheet {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 540, minHeight: 450)
        .onAppear {
            viewModel.auditSystemReadiness()
        }
    }

    // MARK: - Header Banner

    private var headerBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(viewModel.overallReadinessStatus.badgeColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: viewModel.overallReadinessStatus.iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(viewModel.overallReadinessStatus.badgeColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("System Readiness & Permissions")
                        .font(.headline)

                    Text(viewModel.overallReadinessStatus.statusTitle)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(viewModel.overallReadinessStatus.badgeColor.opacity(0.15))
                        .foregroundStyle(viewModel.overallReadinessStatus.badgeColor)
                        .clipShape(Capsule())
                }

                Text(bannerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.auditSystemReadiness()
            } label: {
                Label("Re-scan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var bannerSubtitle: String {
        switch viewModel.overallReadinessStatus {
        case .ready:
            return "All core drivers, binaries, and authorizations are fully operational."
        case .blocked(let msg):
            return "Attention required: \(msg)"
        case .notInstalled(let msg):
            return "Setup required: \(msg)"
        case .warning(let msg):
            return msg
        case .optional(let msg):
            return msg
        }
    }

    // MARK: - Engine Readiness Summary Card

    private var engineSummaryCard: some View {
        let status = viewModel.backendEnvironment
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if viewModel.isInstallingDrivers {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.isSelectedBackendReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isSelectedBackendReady ? .green : .orange)
                        .font(.title2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.isInstallingDrivers ? "Installing NTFS Drivers…" : (status.isSelectedBackendReady ? "NTFS Read/Write Engine Ready" : "NTFS Driver Setup Required"))
                        .font(.system(size: 14, weight: .semibold))

                    Text(viewModel.driverInstallProgressText ?? status.readinessDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Full Disk Access") {
                    viewModel.openFullDiskAccess()
                }
                .controlSize(.small)

                if !status.isSelectedBackendReady {
                    Button {
                        viewModel.installDriversAutomatically()
                    } label: {
                        Label(viewModel.isInstallingDrivers ? "Installing…" : "Install Drivers", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isInstallingDrivers)
                }
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

                    Button {
                        viewModel.installDriversInTerminal()
                    } label: {
                        Label("Install in Terminal", systemImage: "terminal")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(status.isSelectedBackendReady ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(status.isSelectedBackendReady ? Color.green.opacity(0.25) : Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Category Sections

    private func categorySection(category: ReadinessCategory, items: [ReadinessCheckItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(category.rawValue, systemImage: category.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    readinessRow(for: item)
                }
            }
        }
    }

    // MARK: - Row Component

    private func readinessRow(for item: ReadinessCheckItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.status.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(item.status.badgeColor)
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))

                        Text(item.status.statusTitle)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(item.status.badgeColor.opacity(0.15))
                            .foregroundStyle(item.status.badgeColor)
                            .clipShape(Capsule())
                    }

                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(item.detailedInstruction)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let actionTitle = item.actionTitle, let actionType = item.actionType {
                    Button {
                        viewModel.handleReadinessAction(actionType)
                    } label: {
                        Text(actionTitle)
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    item.status.isReady
                        ? Color.secondary.opacity(0.15)
                        : item.status.badgeColor.opacity(0.4),
                    lineWidth: 1
                )
        )
    }
}
