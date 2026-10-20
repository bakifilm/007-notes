import AppKit
import SwiftUI

@main
struct Notes007App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Note") { NoteStore.shared.newNote() }
                        .keyboardShortcut("n")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var store: NoteStore { NoteStore.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "007 Notes"
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: MainView().environmentObject(store))
        w.minSize = NSSize(width: 720, height: 460)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("MainWindow")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Like other Mac apps: the red button only closes the window, the app stays in the Dock (⌘Q quits).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) { store.saveNow() }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { store.requestSync() }

    /// Save on this Mac, and in automatic mode try a last quick sync before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.saveNow()
        guard store.syncMode == .automatic, store.pendingCount > 0, store.isOnline else { return .terminateNow }
        Task {
            // Whichever comes first: the sync finishing, or 5 seconds.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.store.sync() }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            self.store.saveNow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
