import SwiftUI

/// Detailed inspector view for a selected external NTFS volume.
struct DiskDetailView: View {
    let disk: DiskInfo
    @Bindable var viewModel: DashboardViewModel
    @State private var isConfirmingEject = false

    private var isOperatingOnThisDisk: Bool {
        viewModel.isBusy && viewModel.activeDeviceID == disk.deviceIdentifier
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if isOperatingOnThisDisk {
                    TransactionProgressBanner(
                        statusText: viewModel.statusSummary,
                        activeStep: viewModel.activeTransactionStep
                    )
                }

                actionBar

                StorageCapacityCard(disk: disk)

                crystalDiskInfoHealthCard

                if !disk.healthWarnings.isEmpty {
                    warningsSection
                }

                metadataSection
            }
            .padding(22)
        }
        .onAppear {
            viewModel.fetchHealth(for: disk)
        }
        .onChange(of: disk.deviceIdentifier) { _, _ in
            viewModel.fetchHealth(for: disk)
        }
        .sheet(isPresented: $viewModel.isShowingHealthSheet) {
            if let health = viewModel.health(for: disk) {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CrystalDiskInfo Telemetry")
                                .font(.headline)
                            Text("\(disk.name) (/dev/\(disk.deviceIdentifier))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Done") {
                            viewModel.isShowingHealthSheet = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        DiskHealthView(
                            health: health,
                            isLoading: viewModel.isLoadingHealth,
                            onRefresh: { viewModel.fetchHealth(for: disk) },
                            onInstallSmartctl: { viewModel.installSmartmontools() },
                            isInstallingSmartctl: viewModel.isInstallingSmartctl,
                            installProgressText: viewModel.smartctlInstallProgress
                        )
                        .padding(18)
                    }
                }
                .frame(minWidth: 720, minHeight: 520)
            }
        }
        .sheet(isPresented: $viewModel.isShowingFormatSheet) {
            FormatDiskSheetView(disk: disk, viewModel: viewModel)
        }
        .confirmationDialog(
            "Safely eject \(disk.name)?",
            isPresented: $isConfirmingEject,
            titleVisibility: .visible
        ) {
            Button("Safely Eject", role: .destructive) {
                viewModel.safelyEject(for: disk)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ejects the physical disk containing \(disk.deviceIdentifier) (\(disk.parentWholeDisk)), including any other partitions on the same drive.")
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(disk.isWritable ? Color.green.opacity(0.14) : Color.accentColor.opacity(0.14))
                    .frame(width: 60, height: 60)

                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 28))
                    .foregroundStyle(disk.isWritable ? .green : .accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(disk.name)
                        .font(.title2.weight(.bold))
                    MountStateBadge(
                        state: isOperatingOnThisDisk
                            ? .transitioning(viewModel.activeTransactionStep?.progressLabel ?? "Working…")
                            : disk.mountState
                    )
                }

                Text("\(disk.deviceModel) · \(disk.connectionType) · /dev/\(disk.deviceIdentifier)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let mountPoint = disk.mountPoint {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(mountPoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Primary Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if !disk.isWritable {
                Button {
                    viewModel.enableWriteAccess(for: disk)
                } label: {
                    Label("Enable Read/Write Access", systemImage: "lock.open.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(viewModel.isBusy || disk.mediaIdentity == nil)
            } else {
                Button {
                    viewModel.remountReadOnly(for: disk)
                } label: {
                    Label("Switch to Read-Only", systemImage: "lock.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
            }

            if disk.isMounted {
                Button {
                    viewModel.openInFinder(for: disk)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.unmount(for: disk)
                } label: {
                    Label("Unmount", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
            } else {
                Button {
                    viewModel.remountReadOnly(for: disk)
                } label: {
                    Label("Mount Read-Only", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
            }

            Spacer()

            Button(role: .destructive) {
                viewModel.isShowingFormatSheet = true
            } label: {
                Label("Format NTFS…", systemImage: "eraser.line.dashed")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)

            Button(role: .destructive) {
                isConfirmingEject = true
            } label: {
                Label("Safely Eject", systemImage: "eject.fill")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || disk.mediaIdentity == nil)
        }
    }

    // MARK: - Health & Safety Warnings

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Data Safety & Health Notices", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(disk.healthWarnings) { warning in
                VStack(alignment: .leading, spacing: 4) {
                    Text(warning.title)
                        .font(.subheadline.weight(.semibold))
                    Text(warning.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Technical Metadata Grid

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Volume & Filesystem Details", systemImage: "info.circle")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                metadataRow("File System", value: disk.filesystemName)
                Divider()
                metadataRow("Active Backend", value: disk.activeBackendDescription)
                Divider()
                metadataRow("Preferred Engine", value: viewModel.settings.preferredBackend.displayName)
                Divider()
                metadataRow("Mount Point", value: disk.mountPoint ?? "Not Mounted", monospaced: true)
                Divider()
                metadataRow("BSD Device Node", value: "/dev/\(disk.deviceIdentifier) (Parent: /dev/\(disk.parentWholeDisk))", monospaced: true)
                Divider()
                metadataRow("Connection Bus", value: disk.connectionType)
                Divider()
                metadataRow("IOKit Media Identity", value: disk.mediaIdentity ?? "Unavailable", monospaced: true)
                if let partUUID = disk.partitionUUID, !partUUID.isEmpty {
                    Divider()
                    metadataRow("Partition UUID", value: partUUID, monospaced: true)
                }
                if let volUUID = disk.volumeUUID, !volUUID.isEmpty {
                    Divider()
                    metadataRow("Volume UUID", value: volUUID, monospaced: true)
                }
                if let smart = disk.smartStatus, !smart.isEmpty {
                    Divider()
                    metadataRow("SMART Status", value: smart)
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline.weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - CrystalDiskInfo Health & Temperature Card

    private var crystalDiskInfoHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Disk Health & Temperature (CrystalDiskInfo)", systemImage: "waveform.path.ecg")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.isShowingHealthSheet = true
                } label: {
                    Label("Inspect S.M.A.R.T.", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let health = viewModel.health(for: disk) {
                HStack(spacing: 12) {
                    // Mini Health Badge
                    HStack(spacing: 8) {
                        Image(systemName: health.healthGrade.isGood ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(health.healthGrade.isGood ? .blue : .orange)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Health Status")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(health.healthGrade.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(health.healthGrade.isGood ? .blue : .orange)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    // Mini Temperature Badge
                    HStack(spacing: 8) {
                        Image(systemName: "thermometer.medium")
                            .font(.title3)
                            .foregroundStyle(health.temperature.celsius != nil ? .teal : .secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Temperature")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(health.temperature.displayString)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(health.temperature.celsius != nil ? .teal : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    // Media Type
                    HStack(spacing: 8) {
                        Image(systemName: health.mediaType == .ssd ? "internaldrive.fill" : "externaldrive.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Media Type")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(health.mediaType.rawValue)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading disk health and telemetry…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
