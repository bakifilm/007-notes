import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        Group {
            if store.loginState == .loggedIn {
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 300)
                        .background(Color.black.opacity(0.40))
                    Divider()
                    if let note = store.selected {
                        NotePane(note: note)
                    } else {
                        VStack(spacing: 12) {
                            Text(store.visibleNotes.isEmpty ? "No notes yet" : "Select a note")
                                .font(Theme.body)
                                .foregroundStyle(.secondary)
                            Button("New Note") { store.newNote() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete this note?", isPresented: Binding(
            get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } }
        ), presenting: store.pendingDelete) { note in
            Button("Delete “\(note.displayTitle)”", role: .destructive) { store.delete(note.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will also be deleted from \(store.serverName).")
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject var store: NoteStore
    @AppStorage("lastServer") private var server = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            Text("007 Notes").font(.system(size: 22, weight: .semibold))
            Text("Sign in with your Nextcloud account").font(Theme.body).foregroundStyle(.secondary)

            if store.loginState == .waitingForBrowser {
                ProgressView().controlSize(.small).padding(.top, 6)
                Text("Waiting for approval in your browser…").foregroundStyle(.secondary)
                Button("Cancel") { store.cancelLogin() }
            } else {
                TextField("cloud.example.com", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .frame(width: 300)
                    .onSubmit(login)
                    .padding(.top, 6)
                Button("Sign in with Browser", action: login)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = store.loginError {
                Text(error).font(.callout).foregroundColor(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func login() { store.startLogin(serverInput: server) }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: NoteStore
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    Button("All Notes") { store.categoryFilter = nil }
                    if !store.categories.isEmpty { Divider() }
                    ForEach(store.categories, id: \.self) { c in
                        Button(c) { store.categoryFilter = c }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.categoryFilter == nil ? "tray.full" : "folder")
                        Text(store.categoryFilter ?? "All Notes").font(Theme.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()
                SyncButton()
                Button { store.newNote() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("New note (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            SearchField(prompt: "Search", text: $store.search)
                .padding(10)

            if let msg = store.syncMessage {
                Text(msg)
                    .font(Theme.small)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List(selection: $store.selectedId) {
                ForEach(store.visibleNotes) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button(note.favorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(note.id) }
                            Button("Delete…", role: .destructive) { store.pendingDelete = note }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 9) {
                Avatar(name: store.account?.displayName ?? "", url: store.api?.avatarURL(), size: 28)
                Text(store.account?.notebookTitle ?? "Notes")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Menu {
                    Picker("Sync", selection: $store.syncMode) {
                        ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Sync Now") { Task { await store.sync() } }
                    Divider()
                    Button("Sign Out…") { confirmSignOut = true }
                    Button("Quit 007 Notes") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .confirmationDialog("Sign out of 007 Notes?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { store.logout() }
        } message: {
            Text(store.pendingCount > 0
                 ? "\(store.pendingCount) note(s) are not synced yet and will be lost. Sync first if you want to keep them."
                 : "Your notes stay on \(store.serverName).")
        }
    }
}

struct SyncButton: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        Button { Task { await store.sync() } } label: {
            ZStack(alignment: .topTrailing) {
                if store.syncing {
                    ProgressView().controlSize(.small).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15))
                        .frame(width: 20, height: 20)
                }
                if store.pendingCount > 0 && !store.syncing {
                    Text("\(store.pendingCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 8, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help(store.pendingCount > 0 ? "Sync now — \(store.pendingCount) change(s) waiting" : "Sync now")
        .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}

struct NoteRow: View {
    @EnvironmentObject var store: NoteStore
    let note: LocalNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.favorite {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundColor(.yellow)
                }
                Text(note.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusTicks(status: store.status(of: note), size: 10)
            }
            HStack(spacing: 6) {
                Text(Fmt.relative(note.modified)).font(Theme.small).foregroundStyle(.secondary)
                Text(note.preview).font(Theme.preview).foregroundStyle(.secondary).lineLimit(1)
            }
            if !note.category.isEmpty && store.categoryFilter == nil {
                Label(note.category, systemImage: "folder")
                    .font(Theme.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Note

struct NotePane: View {
    @EnvironmentObject var store: NoteStore
    let note: LocalNote
    @State private var newCategory = ""
    @State private var askCategory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(note.displayTitle).font(Theme.title).lineLimit(1)
                if note.readonly {
                    Label("Read-only", systemImage: "lock").font(Theme.small).foregroundStyle(.secondary)
                }
                Spacer()
                FormatBar()
                Divider().frame(height: 18)
                Menu {
                    Button("No Category") { store.setCategory(note.id, "") }
                    ForEach(store.categories, id: \.self) { c in Button(c) { store.setCategory(note.id, c) } }
                    Divider()
                    Button("New Category…") { newCategory = ""; askCategory = true }
                } label: {
                    Label(note.category.isEmpty ? "Category" : note.category, systemImage: "folder")
                        .font(Theme.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { store.toggleFavorite(note.id) } label: {
                    Image(systemName: note.favorite ? "star.fill" : "star")
                        .foregroundColor(note.favorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Favorite")
                Button { store.pendingDelete = note } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.35))

            NoteEditor(noteId: note.id, text: note.content, editable: !note.readonly,
                       focusToken: store.focusToken) { store.updateContent(note.id, $0) }
                .background(Color.black.opacity(0.25))

            StatusBar(note: note)
        }
        .alert("New Category", isPresented: $askCategory) {
            TextField("Name", text: $newCategory)
            Button("Cancel", role: .cancel) {}
            Button("Add") { store.setCategory(note.id, newCategory) }
        }
    }
}

/// Bold / italic / underline / strike / checklist — same as ⌘B ⌘I ⌘U ⇧⌘X ⇧⌘L.
struct FormatBar: View {
    var body: some View {
        HStack(spacing: 2) {
            fmt("bold", "Bold (⌘B)") { MarkdownStyle.toggle("**", "**", in: $0) }
            fmt("italic", "Italic (⌘I)") { MarkdownStyle.toggle("*", "*", in: $0) }
            fmt("underline", "Underline (⌘U)") { MarkdownStyle.toggle("<u>", "</u>", in: $0) }
            fmt("strikethrough", "Strikethrough (⇧⌘X)") { MarkdownStyle.toggle("~~", "~~", in: $0) }
            fmt("checklist", "Checklist (⇧⌘L)") { MarkdownStyle.toggleChecklist(in: $0) }
        }
    }

    private func fmt(_ symbol: String, _ help: String, _ action: @escaping (NSTextView) -> Void) -> some View {
        Button {
            guard let tv = NoteTextView.active, tv.isEditable else { return }
            tv.window?.makeFirstResponder(tv)
            action(tv)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: NoteStore
    let note: LocalNote

    private var words: Int {
        note.content.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var label: String {
        switch store.status(of: note) {
        case .synced(let ts):
            return "Synced with \(store.serverName)" + (ts.map { " · \(Fmt.time($0))" } ?? "")
        case .pending:
            if store.lockedIds.contains(note.id) { return "Saved on this Mac · locked on \(store.serverName), retrying" }
            if !store.isOnline { return "Saved on this Mac · will sync when online" }
            return store.syncMode == .manual ? "Saved on this Mac · not synced yet" : "Saved on this Mac · syncing soon"
        case .syncing:
            return "Syncing…"
        case .failed(let e):
            return "Not synced: \(e)"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Edited \(Fmt.time(note.modified)) · \(words) words")
                .font(Theme.small)
                .foregroundStyle(.secondary)
            Spacer()
            Text(label).font(Theme.small).foregroundStyle(.secondary)
            StatusTicks(status: store.status(of: note), size: 11)
            if note.needsUpload && !store.syncing {
                Button(store.syncMode == .manual ? "Sync Now" : "Retry") { Task { await store.sync() } }
                    .buttonStyle(.link)
                    .font(Theme.small)
                    .opacity(store.syncMode == .manual || note.error != nil ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.40))
    }
}
