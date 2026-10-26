import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var vault: Vault!
    private var runner: AgentRunner!
    private var controllers: [String: NoteWindowController] = [:]
    private var layout = WindowLayout()
    private var todoWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var runnerMenuItem: NSMenuItem?
    private var pendingLayoutSave: DispatchWorkItem?

    private static let vaultPathKey = "vaultPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        openVault(at: Self.savedVaultURL())
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeVault()
    }

    // MARK: 프로젝트 폴더

    private static func savedVaultURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: vaultPathKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widgent", isDirectory: true)
    }

    private func openVault(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        UserDefaults.standard.set(url.path, forKey: Self.vaultPathKey)

        vault = Vault(root: url)
        runner = AgentRunner(vault: vault)
        layout = vault.loadLayout()

        let open = layout.open.filter { vault.documents[$0] != nil }
        if open.isEmpty {
            openNote(Vault.mainNotePath)
        } else {
            open.forEach { openNote($0) }
        }
    }

    private func closeVault() {
        guard vault != nil else { return }
        saveLayoutNow()
        runner.shutdown()
        vault.close()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
        todoWindow?.close()
        todoWindow = nil
    }

    @objc private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더 사용"
        panel.message = "메모(md 파일)를 둘 프로젝트 폴더를 고르세요. 옵시디언 vault도 그대로 쓸 수 있어요."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeVault()
        openVault(at: url)
    }

    @objc private func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([vault.root])
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(vault.configURL)
    }

    // MARK: 메모 창

    @objc private func openMainNote() {
        openNote(Vault.mainNotePath, focus: true)
    }

    @objc private func newNote() {
        openNote(vault.createUntitledNote().relativePath, focus: true)
    }

    private func openLink(_ link: String) {
        guard let doc = vault.documentForLink(link) else { return }
        openNote(doc.relativePath, focus: true)
    }

    private func openNote(_ path: String, focus: Bool = false) {
        if let existing = controllers[path] {
            if focus {
                NSApp.activate()
                existing.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let document = vault.documents[path] else { return }

        let state = layout.states[path] ?? WindowState(frame: defaultFrame())
        let controller = NoteWindowController(document: document, state: state, runner: runner)
        controller.onLayoutChange = { [weak self] in self?.scheduleLayoutSave() }
        controller.onOpenLink = { [weak self] in self?.openLink($0) }
        controller.onNew = { [weak self] in self?.newNote() }
        controller.onShowTodos = { [weak self] in self?.showTodos() }
        controller.onClose = { [weak self] controller in
            self?.controllers[controller.note.relativePath] = nil
            self?.scheduleLayoutSave()
        }
        controllers[path] = controller
        controller.showWindow(nil)
        if focus {
            NSApp.activate()
            controller.window?.makeKeyAndOrderFront(nil)
        }
        scheduleLayoutSave()
    }

    private func defaultFrame() -> CGRect {
        let size = CGSize(width: 300, height: 340)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(controllers.count % 8) * 24
        return CGRect(
            origin: CGPoint(x: visible.maxX - size.width - 40 - offset, y: visible.maxY - size.height - 40 - offset),
            size: size
        )
    }

    private func scheduleLayoutSave() {
        pendingLayoutSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveLayoutNow() }
        }
        pendingLayoutSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveLayoutNow() {
        pendingLayoutSave?.cancel()
        for (path, controller) in controllers {
            layout.states[path] = controller.state
        }
        layout.open = controllers.keys.sorted()
        vault.saveLayout(layout)
    }

    // MARK: 할 일 창

    @objc private func showTodos() {
        if todoWindow == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "할 일"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TodoPanelView(
                vault: vault,
                runner: runner,
                onOpenNote: { [weak self] in self?.openNote($0, focus: true) },
                onOpenConfig: { [weak self] in self?.openConfig() }
            ))
            window.center()
            todoWindow = window
        }
        NSApp.activate()
        todoWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleRunner() {
        runner.isEnabled.toggle()
    }

    // MARK: 메뉴

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Widgent")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "메인 메모", action: #selector(openMainNote), keyEquivalent: "").target = self
        menu.addItem(withTitle: "새 메모", action: #selector(newNote), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "할 일 모아보기", action: #selector(showTodos), keyEquivalent: "t").target = self
        menu.addItem(.separator())
        let runnerItem = menu.addItem(withTitle: "에이전트 자동 실행", action: #selector(toggleRunner), keyEquivalent: "")
        runnerItem.target = self
        runnerMenuItem = runnerItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "프로젝트 폴더 바꾸기…", action: #selector(chooseVault), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Finder에서 보기", action: #selector(revealVault), keyEquivalent: "").target = self
        menu.addItem(withTitle: "설정 파일 열기", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Widgent 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        runnerMenuItem?.state = runner.isEnabled ? .on : .off
    }

    // Dock 아이콘이 없는 앱이라 메뉴는 안 보이지만, ⌘C/⌘V/⌘Z 같은 단축키는 메인 메뉴가 있어야 동작함
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "새 메모", action: #selector(newNote), keyEquivalent: "n").target = self
        appMenu.addItem(withTitle: "할 일 모아보기", action: #selector(showTodos), keyEquivalent: "t").target = self
        appMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Widgent 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
