import SwiftUI

/// Application Settings window implementing all options required in Section 8 of `agents.md`.
struct SettingsView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var lockSelfTestResult: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            readinessTab
                .tabItem {
                    Label("System & Permissions", systemImage: "checkmark.shield")
                }

            backendTab
                .tabItem {
                    Label("Filesystem Engine", systemImage: "externaldrive.badge.timemachine")
                }

            securityAndDiagnosticsTab
                .tabItem {
                    Label("Security & Logs", systemImage: "lock.shield")
                }
        }
        .frame(width: 580, height: 480)
        .padding(8)
    }

    // MARK: - Readiness Tab

    private var readinessTab: some View {
        SystemReadinessView(viewModel: viewModel, isPresentedAsSheet: false)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Automount & Finder Integration") {
                Toggle("Automatically mount connected NTFS drives", isOn: $viewModel.settings.autoMountNTFS)

                Picker("Default mount mode", selection: $viewModel.settings.defaultMountWritable) {
                    Text("Read / Write (via ntfs-3g)").tag(true)
                    Text("Read-Only (macOS Safe Mode)").tag(false)
                }

                Toggle("Open volume in Finder after enabling write access", isOn: $viewModel.settings.openFinderAfterMount)

                Toggle("Show non-NTFS external volumes (exFAT, FAT32, APFS)", isOn: Binding(
                    get: { viewModel.settings.showNonNTFSVolumes },
                    set: { newValue in
                        viewModel.toggleShowNonNTFS(newValue)
                    }
                ))
            }

            Section("Startup & Menu Bar") {
                Toggle("Launch application at login", isOn: $viewModel.settings.launchAtLogin)
                Text("Login Item Status: \(viewModel.settings.launchAtLoginStatusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show menu bar utility icon", isOn: $viewModel.settings.showMenuBarIcon)
                Toggle("Show connected NTFS volume count in menu bar", isOn: $viewModel.settings.showVolumeCountInMenuBar)
                Toggle("Show notifications for mount/unmount events", isOn: $viewModel.settings.enableNotifications)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Filesystem Engine Tab

    private var backendTab: some View {
        Form {
            Section("Active Engine Architecture") {
                Picker("Backend Engine", selection: $viewModel.settings.preferredBackend) {
                    ForEach(FilesystemBackendType.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(viewModel.settings.preferredBackend.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed Driver Status") {
                LabeledContent("ntfs-3g Executable") {
                    Text(viewModel.backendEnvironment.ntfs3gPath ?? "Not Found")
                        .font(.caption.monospaced())
                        .foregroundStyle(viewModel.backendEnvironment.hasNTFS3G ? .green : .orange)
                }

                LabeledContent("macFUSE Bundle") {
                    Text(viewModel.backendEnvironment.macFUSEInstalled ? "/Library/Filesystems/macfuse.fs" : "Not Installed")
                        .font(.caption.monospaced())
                        .foregroundStyle(viewModel.backendEnvironment.macFUSEInstalled ? .green : .orange)
                }

                LabeledContent("Apple FSKit Support (macOS 15.4+)") {
                    Text(viewModel.backendEnvironment.fskitSupportedOnOS ? "Supported" : "Requires macOS 15.4+")
                        .font(.caption)
                        .foregroundStyle(viewModel.backendEnvironment.fskitSupportedOnOS ? .green : .secondary)
                }

                HStack {
                    if !viewModel.backendEnvironment.isSelectedBackendReady {
                        Button {
                            viewModel.installDriversAutomatically()
                        } label: {
                            Label(
                                viewModel.isInstallingDrivers ? "Installing Drivers…" : "Install Drivers Automatically",
                                systemImage: "arrow.down.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isInstallingDrivers)

                        Button {
                            viewModel.installDriversInTerminal()
                        } label: {
                            Label("Install in Terminal", systemImage: "terminal")
                        }
                        .disabled(viewModel.isInstallingDrivers)
                    }

                    Button("Refresh Driver Status") {
                        viewModel.refreshBackendStatus()
                    }
                    .disabled(viewModel.isInstallingDrivers)

                    Button("Open Full Disk Access…") {
                        viewModel.openFullDiskAccess()
                    }
                }

                if let progress = viewModel.driverInstallProgressText {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Security & Diagnostics Tab

    private var securityAndDiagnosticsTab: some View {
        Form {
            Section("Authorization & Data Protection") {
                Toggle("Require Touch ID / biometric confirmation before mounting", isOn: $viewModel.settings.requireBiometricConfirmation)

                Text("Data Safety Policy: u-NTFS always mounts with -o rw,norecover,allow_other,default_permissions. Hibernated or dirty NTFS volumes are never forced or wiped automatically; if any write check fails, the drive is automatically restored to macOS read-only mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics & Self-Test") {
                Toggle("Enable verbose diagnostic logging", isOn: $viewModel.settings.enableDiagnosticLogging)

                HStack {
                    Button("Run SystemDeviceLock Self-Test") {
                        let passed = SystemDeviceLock.selfTest()
                        lockSelfTestResult = passed
                            ? "PASS: Shared device lock contention, token ownership, reuse, and symlink refusal verified."
                            : "FAIL: Device lock self-test encountered an unexpected error."
                    }

                    if let lockSelfTestResult {
                        Text(lockSelfTestResult)
                            .font(.caption)
                            .foregroundStyle(lockSelfTestResult.hasPrefix("PASS") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
