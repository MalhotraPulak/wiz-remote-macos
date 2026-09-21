import SwiftUI

@main
struct WizRemoteMenuBarApp: App {
    @StateObject private var viewModel = BulbService(autoConnect: true)
    @StateObject private var launchAtLogin = LaunchAtLoginController(enableOnFirstLaunch: true)
    @StateObject private var musicSync = MusicSyncController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                viewModel: viewModel,
                launchAtLogin: launchAtLogin,
                musicSync: musicSync
            )
        } label: {
            Image(systemName: menuBarIcon)
                .accessibilityLabel("WiZ Remote")
                .task {
                    if viewModel.bulbs.isEmpty {
                        viewModel.connectBulbs()
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        if viewModel.isScanning {
            return "lightbulb.min"
        }
        if viewModel.bulbs.contains(where: { $0.isOn == true }) {
            return "lightbulb.fill"
        }
        return "lightbulb"
    }
}
