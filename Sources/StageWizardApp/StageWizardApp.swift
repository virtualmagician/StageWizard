import SwiftUI

/// Routes Finder double-clicks and Open Recent onto the document controller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var appModel: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Locked dark appearance — predictable at the tech table.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Self.appModel?.document.open(url: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document = Self.appModel?.document else { return .terminateNow }
        return document.confirmQuit() ? .terminateNow : .terminateCancel
    }
}

@main
struct StageWizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    init() {
        AppDelegate.appModel = _app.wrappedValue
    }

    var body: some Scene {
        Window("StageWizard", id: "main") {
            ContentView()
                .environment(app)
                .environment(app.document)
                .frame(minWidth: 980, minHeight: 600)
        }
        .commands {
            ShowCommands(document: app.document, app: app)
        }
    }
}
