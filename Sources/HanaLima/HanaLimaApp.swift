import AppKit
import LimaKit
import SwiftUI

@main
struct HanaLimaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        model.agentHost.launch()
    }

    var body: some Scene {
        // A single window, so the menu bar can bring it back instead of opening another.
        Window("HanaLima", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(AppSettings.opensWindowAtLaunch ? .automatic : .suppressed)
        .restorationBehavior(AppSettings.launchedByMCP ? .disabled : .automatic)
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
        .restorationBehavior(AppSettings.launchedByMCP ? .disabled : .automatic)
        .windowResizability(.contentSize)

        // The rescue boot's screen (the VM run by HanaLima, see RescueSession).
        Window("救出起動", id: "rescue") {
            RescueWindowView()
                .environment(model)
        }
        .restorationBehavior(AppSettings.launchedByMCP ? .disabled : .automatic)
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

    /// Accept tool calls from MCP clients through `hanalima-mcp` (docs/14). Off by default.
    /// The helper reads this key too (CFPreferences, domain org.izawa.HanaLima) to decide
    /// whether launching the app would help.
    static let acceptAIOperationsKey = "acceptAIOperations"
    static var acceptsAIOperations: Bool {
        #if DEBUG
        // Lets a development build be tried without changing the installed app's setting.
        if ProcessInfo.processInfo.environment["HANALIMA_MCP_ACCEPT"] == "1" { return true }
        #endif
        return UserDefaults.standard.bool(forKey: acceptAIOperationsKey)
    }

    /// Set by `hanalima-mcp` when it launches the app (`open -g --env`): stay in the background.
    static var launchedByMCP: Bool { ProcessInfo.processInfo.environment["HANALIMA_MCP_LAUNCH"] == "1" }

    /// A launch by the MCP helper stays out of sight, but only while the menu bar item is shown:
    /// that item is what opens the window later (for an approval), and without it the user
    /// would have no way in.
    static var opensWindowAtLaunch: Bool { !(launchedByMCP && isMenuBarExtraShown) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Launched by the MCP helper: don't take the user's focus.
        if !AppSettings.launchedByMCP { NSApp.activate() }
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
