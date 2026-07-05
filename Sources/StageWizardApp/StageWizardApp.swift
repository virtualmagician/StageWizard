import SwiftUI

/// Routes Finder double-clicks and Open Recent onto the document controller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var appModel: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Locked dark appearance — predictable at the tech table.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reopen the last show. Deferred one runloop turn so a
        // Finder-initiated application(_:open:) wins; skipped once anything
        // is open or edited. Missing files are skipped; a corrupt file
        // alerts inside open(url:) and leaves the blank untitled show.
        Task { @MainActor in
            guard let document = Self.appModel?.document,
                  document.fileURL == nil, !document.isDirty else { return }
            var candidates: [URL] = []
            if let last = UserDefaults.standard.string(forKey: ShowDocumentController.lastShowPathKey) {
                candidates.append(URL(fileURLWithPath: last))
            }
            candidates.append(contentsOf: NSDocumentController.shared.recentDocumentURLs)
            if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                document.open(url: url)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Self.appModel?.document.open(url: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = Self.appModel else { return .terminateNow }
        // A locked workspace exists to swallow stray keystrokes — that
        // includes a stray ⌘Q. Cancel is the default button: Return must
        // never quit mid-show.
        if app.mode != .edit {
            let alert = NSAlert()
            alert.messageText = "StageWizard is in \(app.mode == .show ? "Show" : "Rehearsal") mode."
            alert.informativeText = "Quitting stops all playback and closes the workspace."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        return app.document.confirmQuit() ? .terminateNow : .terminateCancel
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
                .tint(Theme.accent)   // MagicLab brand accent, app-wide
                .frame(minWidth: 980, minHeight: 600)
                // Re-affirm with the INSTALLED model: SwiftUI recreates the
                // App struct freely, and each re-init would otherwise leave
                // the weak delegate hook pointing at a discarded throwaway —
                // silently disabling the quit dialog and Finder opens.
                .onAppear { AppDelegate.appModel = app }
        }
        .commands {
            ShowCommands(document: app.document, app: app)
        }
    }
}
