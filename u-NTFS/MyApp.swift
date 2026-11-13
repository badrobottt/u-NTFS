import SwiftUI

@main
struct MyApp: App {
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup("u-NTFS", id: "dashboard") {
            DashboardView(viewModel: viewModel)
                .frame(minWidth: 780, minHeight: 520)
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra(isInserted: $viewModel.settings.showMenuBarIcon) {
            MenuBarView(viewModel: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.writableCount > 0 ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                if viewModel.settings.showVolumeCountInMenuBar && !viewModel.disks.isEmpty {
                    Text("\(viewModel.disks.count)")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
