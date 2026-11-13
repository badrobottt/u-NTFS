import SwiftUI

/// Main application dashboard window with sidebar volume list, driver readiness banner, and detailed disk inspector.
struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            detailContent
        }
        .navigationTitle("u-NTFS")
        .navigationSubtitle(viewModel.statusSummary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.refreshAll()
                } label: {
                    Label("Refresh Volumes", systemImage: "arrow.clockwise")
                }
                .help("Rescan connected external NTFS drives and driver status")
                .disabled(viewModel.isBusy || viewModel.isScanning)

                Button {
                    viewModel.diagnosticsSheetMode = .logs
                    viewModel.isShowingDiagnosticsSheet = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .help("View activity logs, disk scan report, and driver installation status")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Configure automatic NTFS mounting, backend engine, and security")
            }
        }
        .sheet(isPresented: $viewModel.isShowingDiagnosticsSheet) {
            DiagnosticsSheetView(viewModel: viewModel)
        }
        .alert(item: $viewModel.activeAlert) { alert in
            if alert.offerFullDiskAccess {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Full Disk Access")) {
                        viewModel.openFullDiskAccess()
                    },
                    secondaryButton: .default(Text("Show Diagnostics")) {
                        viewModel.diagnosticsSheetMode = .logs
                        viewModel.isShowingDiagnosticsSheet = true
                    }
                )
            } else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("OK")),
                    secondaryButton: .default(Text("Show Diagnostics")) {
                        viewModel.diagnosticsSheetMode = .logs
                        viewModel.isShowingDiagnosticsSheet = true
                    }
                )
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedDiskID) {
                Section("External NTFS Drives (\(viewModel.disks.count))") {
                    if viewModel.disks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("No NTFS Drives Detected", systemImage: "externaldrive.badge.questionmark")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Connect a USB or Thunderbolt NTFS drive. macOS mounts NTFS read-only by default; u-NTFS enables full Finder write access.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(viewModel.disks) { disk in
                            SidebarDiskRow(disk: disk)
                                .tag(disk.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Compact footer showing active backend engine & status
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.backendEnvironment.isSelectedBackendReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.settings.preferredBackend.shortName)
                        .font(.caption.weight(.semibold))
                    Text(viewModel.backendEnvironment.hasNTFS3G ? "ntfs-3g detected" : "ntfs-3g missing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.runInstallationCheckAndShowSheet()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("Check NTFS driver & backend installation")
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: - Detail Pane

    private var detailContent: some View {
        VStack(spacing: 0) {
            BackendReadinessCard(
                status: viewModel.backendEnvironment,
                isInstallingDrivers: viewModel.isInstallingDrivers,
                installProgressText: viewModel.driverInstallProgressText,
                onInstallDrivers: {
                    viewModel.installDriversAutomatically()
                },
                onInstallInTerminal: {
                    viewModel.installDriversInTerminal()
                },
                onCheckInstallation: {
                    viewModel.runInstallationCheckAndShowSheet()
                },
                onOpenFullDiskAccess: {
                    viewModel.openFullDiskAccess()
                }
            )
            .padding(.horizontal, 22)
            .padding(.top, 16)

            if let selected = viewModel.selectedDisk {
                DiskDetailView(disk: selected, viewModel: viewModel)
            } else {
                emptyStateView
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "externaldrive.connected.to.line.below")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            Text("Connect an External NTFS Drive")
                .font(.title2.weight(.semibold))

            Text("Plug in an external USB or Thunderbolt NTFS storage device.\nu-NTFS automatically detects NTFS partitions via DiskArbitration, verifies hardware IOMedia identity, and mounts them with full Read/Write support in macOS Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button {
                    viewModel.refreshAll()
                } label: {
                    Label("Scan for Drives", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.isScanning)

                Button {
                    viewModel.diagnosticsSheetMode = .scanReport
                    viewModel.isShowingDiagnosticsSheet = true
                } label: {
                    Label("View Disk Scan Report", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Sidebar row representing a single connected external NTFS volume.
private struct SidebarDiskRow: View {
    let disk: DiskInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: disk.isWritable ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(disk.isWritable ? .green : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(disk.deviceIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(disk.isMounted ? (disk.isReadOnly ? "Read-Only" : "Writable") : "Unmounted")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(disk.isWritable ? .green : (disk.isMounted ? .orange : .secondary))
                }
            }

            Spacer()
        }
        .padding(.vertical, 3)
    }
}
