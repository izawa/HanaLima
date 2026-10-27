import AppKit
import LimaKit
import SwiftUI

@main
struct HanaLimaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        // A single window, so the menu bar can bring it back instead of opening another.
        Window("HanaLima", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新規仮想マシン…") { model.createRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.client == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("再読み込み") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        // The installer's screen (Virtualization.framework) lives in its own window.
        Window("インストール", id: "installer") {
            InstallerWindowView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum AppSettings {
    static let showMenuBarExtra = "showMenuBarExtra"
    /// `ansible-playbook` chosen by the user (empty: look in the usual places).
    static let ansiblePathKey = "ansiblePath"
    static var ansiblePath: String? {
        let s = UserDefaults.standard.string(forKey: ansiblePathKey) ?? ""
        return s.isEmpty ? nil : s
    }

    /// UserDefaults has no value until the user changes the setting; the default is on.
    static var isMenuBarExtraShown: Bool {
        UserDefaults.standard.object(forKey: showMenuBarExtra) as? Bool ?? true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessRunner.terminateBackgroundProcesses()
    }

    /// With the menu bar item shown, closing the window leaves HanaLima running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.isMenuBarExtraShown
    }
}
