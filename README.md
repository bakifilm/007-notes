# 007 Notes

A small, fast Nextcloud Notes app for macOS — sibling of [007 Talk](https://github.com/bakifilm/007-talk).

- **Offline first:** every change is saved on this Mac at once and synced afterwards. New notes never jump or duplicate.
- **Status ticks** like WhatsApp: ✓ saved on this Mac, blue ✓✓ synced with the server, ⚠︎ problem.
- **Sync: Automatic or Manual** (gear menu). Manual = nothing leaves the Mac until you press Sync (⇧⌘S).
- **Markdown look:** `~~strike~~`, `**bold**`, `*italic*`, `<u>underline</u>`, `# headings`, `- [ ]` checklists (click to tick), links. The note stays plain Markdown, so Quillpad / the Nextcloud web app see the same text.
- Shortcuts: ⌘N new note, ⌘B ⌘I ⌘U, ⇧⌘X strikethrough, ⇧⌘L checklist.
- Conflicts never lose text: if a note was changed on two devices, the other version is kept as a separate note.
- Sign in through the browser (Nextcloud Login Flow), profile photo and name from your account.

## Install
Download `007-Notes-x.y.z.zip` from [Releases](../../releases), move **007 Notes.app** to Applications.
First launch: **System Settings → Privacy & Security → Open Anyway**.

## Build
GitHub Actions builds every push; bumping `VERSION` on `main` publishes a release.
