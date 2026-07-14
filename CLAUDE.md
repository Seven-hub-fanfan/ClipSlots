# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (SPM, macOS 13+, `-parse-as-library`)
swift build

# Sign + install + restart
codesign --force --deep --sign - .build/debug/ClipSlots
cp -f .build/debug/ClipSlots /Applications/ClipSlots.app/Contents/MacOS/ClipSlots
killall ClipSlots 2>/dev/null; open /Applications/ClipSlots.app
```

DMG: `hdiutil create -fs HFS+ -srcfolder /Applications/ClipSlots.app -volname "ClipSlots vX.Y.Z" ClipSlots_vX.Y.Z.dmg`

Release: `gh release create vX.Y.Z --title "..." --notes "..." ClipSlots_vX.Y.Z.dmg`

## CLI (`clipslots`) — v2.9.0+

A standalone command-line tool for agents lives in target **`ClipSlotsCLI`** (`Sources/ClipSlotsCLI/main.swift`). It reuses the exact data layer via the shared library target **`ClipSlotsKit`** (moved data files: `ClipboardManager`, `SlotStorage`, `SpecialSlotStorage`, `SpecialSlotModels`, `Config`, `HotkeyTemplate`, `SlotContent+*Detection`). Both `ClipSlots` (GUI) and `ClipSlotsCLI` depend on `ClipSlotsKit`.

Commands: `version help groups pages list read write search paste clear create-group create-page write-attachment`. All output a single JSON object (`{"ok":true,...}` / `{"ok":false,"error":...}`). See `docs/clipslots-cli-skill-draft.md` for the agent usage skill + storage rules.

Install (built product is `.build/debug/ClipSlotsCLI`):
```bash
codesign --force --sign - .build/debug/ClipSlotsCLI
cp -f .build/debug/ClipSlotsCLI ~/bin/clipslots   # canonical path agents call
```

⚠️ **Case-insensitive filesystem gotcha:** macOS APFS/HFS+ is case-INSENSITIVE. Do NOT copy the CLI into the app bundle as `Contents/MacOS/clipslots` — it collides with the GUI binary `Contents/MacOS/ClipSlots` (same file!) and silently overwrites the GUI, causing launch crashes. If bundling the CLI, use a distinct name: `Contents/MacOS/clipslots-cli`.

### In-App CLI Install (v2.9.6+)

The Settings page ("命令行工具 (CLI)" section, `CLIInstallManager.swift`) lets users install/update/uninstall the CLI. It bundles the CLI inside the app as `Contents/MacOS/clipslots-cli` and symlinks `/usr/local/bin/clipslots` → that bundled binary (via a macOS admin-auth `do shell script ... with administrator privileges` dialog). Status (installed/outdated/not-installed) is derived by comparing `clipslots version` at the target path vs the bundled binary. **Release pipeline must bundle the CLI**: after building, `cp -f .build/debug/ClipSlotsCLI /Applications/ClipSlots.app/Contents/MacOS/clipslots-cli && codesign --force --sign - /Applications/ClipSlots.app/Contents/MacOS/clipslots-cli`.

## Architecture

**ClipSlots** is a macOS clipboard manager with 10-slot groups ("槽位组"), organized into pages. Global hotkeys (Carbon) save/copy/paste clipboard content across apps.

### Data Model (3-tier hierarchy)

```
Page → SpecialSlot (slot group) → Slot (1-10)
```

- **`SlotPage`**: top-level workspace, e.g. "Work" / "Personal"
- **`SpecialSlot`** (a.k.a. "槽位组" in UI): a named group of exactly 10 slots, belongs to one page
- **`Slot`**: numbered 1-10 within a group, holds one `SlotContent`

### Core Source Files (39 files, main.swift = 2012 lines)

| File | Role |
|------|------|
| `main.swift` | `@main App` + `SlotStoreObservable` (ALL business logic: save/copy/paste/batch-import/search/state) |
| `AppDelegate.swift` | NSApp lifecycle, bridges `store` to `HotKeyManager`, owns `RadialMenuWindowController` |
| `HotKeyManager.swift` | Carbon `RegisterEventHotKey` — DO NOT modify registration logic |
| `ClipboardManager.swift` | `capture()`/`restore()` NSPasteboard via `SlotContent` items |
| `SlotContent+*.swift` | Extensions: file detection (`primaryFileURL`, `detectedFolderURLs`), URL detection, thumbnail |
| `SlotStorage.swift` | JSON-file-based persistence: one JSON per special-slot in `~/.local/share/clipslots/slots/` |
| `SpecialSlotStorage.swift` | Page/SpecialSlot CRUD + migration + index management |
| `SpecialSlotModels.swift` | `SlotPage`, `SpecialSlot`, `FolderOverflowDecision` structs |
| `Config.swift` | `AppConfig` from `~/.config/clipslots/config.toml` (TOML) |
| `BatchImportService.swift` | Batch file detection from clipboard, folder expansion, capacity calc |
| `FolderImportService.swift` | Folder preview, `makeSlotContent(for:)`, `expandSelection(urls:mode:sortRule:)` |
| `ImportLimitMode.swift` | `firstTenTotal / allTotal / firstTenPerFolder / allPerFolder` enum |
| `FloatingNotice.swift` | `FloatingNotice` model + `FloatingNoticeView` (HUD) + `SlotContent.noticeSummary` |
| `FloatingNoticeWindowController.swift` | Global non-activating NSPanel HUD (v2.6.3) |
| `ContentView.swift` | Main window UI: slot cards, search, toolbar, page selector |
| `SettingsView.swift` | Preferences window — DO NOT modify core logic |
| `RadialMenuView.swift` | Radial menu UI — DO NOT modify |
| `RadialMenuWindowController.swift` | Radial menu window — DO NOT modify |
| `ThumbnailProvider.swift` | Async thumbnail generation + in-memory cache |
| `SlotThumbnailView.swift` | SwiftUI view for rendering cached thumbnails |
| `SlotCardView.swift` | Single slot card UI |
| `GlobalSearchResultsView.swift` | Cross-page/group search results view |
| `HotkeyTemplate.swift` | Hotkey template model (`numeric/customKeys`) |
| `UserPreferenceKeys.swift` | UserDefaults keys + typed extensions |

### Key Patterns

**SlotStoreObservable** is the god class — all mutation goes through it. It holds `@Published` slots, pages, specialSlots, floatingNotice, etc. It is assigned to `AppDelegate.store` in `ContentView.onAppear`.

**Hotkey flow**: `HotKeyManager` (Carbon) → `AppDelegate` closures → `store.captureSelectionAndSaveToSlot(_:)` / `store.pasteSlot(_:)`

**Save flow**: `captureSelectionAndSaveToSlot` sends Cmd+C → waits for clipboard change → captures → overwrite confirmation → `handleCapturedContentForSave` → batch detection → single save or `handleBatchSave`

**Paste flow**: `pasteSlot` reads from disk → restores clipboard → sends Cmd+V to previous app

**Batch import**: `startToolbarImport()` (NSOpenPanel multi-select) → `presentImportOptions(for:)` (NSAlert with radio buttons) → `executeToolbarImport` → `folderImportService.expandSelection` → `handleBatchSave`

**HUD**: `showFloatingNotice` sets `@Published floatingNotice` (ContentView overlay) + calls `FloatingNoticeWindowController.shared.show()` (global NSPanel). No background/shadow since v2.6.5.

**Storage**: `~/.local/share/clipslots/slots/<specialSlotId>.json` per group. `~/.config/clipslots/config.toml` for config.

### Forbidden Modifications

These files must NOT be modified unless explicitly instructed:
- `RadialMenuView.swift`
- `RadialMenuWindowController.swift`
- `HotKeyManager.swift` (especially registration logic — `register()`, `unregisterAll()`, `setupHotKeys()`)
- `AppDelegate.swift`
- `SettingsView.swift` (core logic)

Hotkey semantics must be preserved: Cmd+1~0 = paste, Ctrl+Option+1~0 = save. Search must not reorder slots or change Cmd+1~0 semantics.

### Production Code Safety

- `handleBatchSave` in `main.swift`: NEVER use `for n in 1...X` without guarding `X > 0` — Swift traps on `1...0`
- Never use `assertionFailure`/`fatalError`/`precondition` in user-triggerable code paths — replace with HUD notice + return
- Never force-unwrap `currentPage!`/`currentGroup!` — guard with HUD

## Collaboration Workflow (v2.7+)

### Task Delivery Formats

User delivers tasks in two formats. Always check the user's message for these patterns:

**Format A — Feishu Document Links:**
```
https://bytedance.sg.larkoffice.com/docx/...  执行
```
→ Fetch ALL documents with lark-cli, read them thoroughly, then implement.

**Format B — Downloaded Files:**
```
'/path/to/说明.md'  '/path/to/patch'  '/path/to/main.swift'  执行
```
→ Read ALL files (说明.md first, then patch, then main.swift for reference), then implement.

### Execution Pipeline (MANDATORY — NEVER skip any step)

After implementing all changes, execute this exact sequence. Each step is required:

1. **Build**: `swift build` — fix real errors, ignore SourceKit "Cannot find type 'X'" spurious errors
2. **Sign**: `codesign --force --deep --sign - .build/debug/ClipSlots`
3. **Install**: `cp -f .build/debug/ClipSlots /Applications/ClipSlots.app/Contents/MacOS/ClipSlots`
4. **Launch**: `killall ClipSlots 2>/dev/null; open /Applications/ClipSlots.app`
5. **Version number**: Update `Text("vX.Y.Z")` in `ContentView.swift` → MUST do this before commit
6. **Commit**: `git add -A && git commit -m "vX.Y.Z: <description>"`
7. **Push**: `git push origin main`
8. **Tag**: `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`
9. **DMG**: `hdiutil create -fs HFS+ -srcfolder /Applications/ClipSlots.app -volname "ClipSlots vX.Y.Z" ClipSlots_vX.Y.Z.dmg`
10. **Release**: `gh release create vX.Y.Z --title "..." --notes "..." ClipSlots_vX.Y.Z.dmg`
11. **Clean DMG**: `rm -f ClipSlots_vX.Y.Z.dmg` (do NOT commit DMG files)

### Critical Rules

- **Never skip the push step.** After commit, always `git push origin main`.
- **Never skip the version number.** Always update `ContentView.swift` version string before commit.
- **Never skip the release.** Every version gets a DMG + GitHub Release.
- **Always replace the computer's running version.** Step 3-4 ensures this.
- **SourceKit errors are almost always false positives** in this project. If `swift build` succeeds, ignore them and proceed.
- **Do NOT commit DMG files.** They are build artifacts, not source code.
- **After /compact or context restoration**, re-read CLAUDE.md and pick up from where you left off without asking questions.
