import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var library: NoteLibrary!
    private var runner: AgentRunner!
    /// 작업 폴더 즐겨찾기는 메모 폴더를 바꿔도 유지
    private let workspaces = WorkspaceStore()
    private var logos: LogoDirector?
    private var controllers: [String: NoteWindowController] = [:]
    private var layout = WindowLayout()
    private var todoWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var runnerMenuItem: NSMenuItem?
    private var pendingLayoutSave: DispatchWorkItem?

    /// 메모 폴더 경로 (예전 키 이름 그대로 써서 기존 설정 유지)
    private static let notesPathKey = "vaultPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        // 테스트용: --notes <메모 폴더> --autorun 으로 띄우면 사용자 설정을 건드리지 않음
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--notes"), arguments.indices.contains(index + 1) {
            openLibrary(at: URL(fileURLWithPath: arguments[index + 1], isDirectory: true), remember: false,
                      autorun: arguments.contains("--autorun") ? true : nil)
        } else {
            openLibrary(at: Self.savedNotesFolderURL())
        }
        if let index = arguments.firstIndex(of: "--preview-workspaces"), arguments.indices.contains(index + 1) {
            previewWorkspaces(arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--show-settings") {
            openSettings(tab: arguments.indices.contains(index + 1) ? arguments[index + 1] : "general")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeLibrary()
    }

    // MARK: 프로젝트 폴더

    private static func savedNotesFolderURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: notesPathKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twinkle", isDirectory: true)
    }

    private func openLibrary(at url: URL, remember: Bool = true, autorun: Bool? = nil) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if remember { UserDefaults.standard.set(url.path, forKey: Self.notesPathKey) }

        library = NoteLibrary(root: url)
        runner = AgentRunner(library: library, enabledOverride: autorun)
        layout = library.loadLayout()

        AgentLogos.overrideDirectory = AppPaths.logos
        let logos = LogoDirector(runner: runner)
        logos.workAnchor = { [weak self] job in
            self?.controllers[job.todo.docPath]?.anchor(forTodoBody: job.todo.body)
        }
        logos.idleAnchor = { [weak self] index in
            guard let self else { return nil }
            let home = controllers[NoteLibrary.mainNotePath] ?? controllers.values.first
            return home?.idleAnchor(index: index)
        }
        self.logos = logos

        let open = layout.open.filter { library.documents[$0] != nil }
        if open.isEmpty {
            openNote(NoteLibrary.mainNotePath)
        } else {
            open.forEach { openNote($0) }
        }
    }

    private func closeLibrary() {
        guard library != nil else { return }
        saveLayoutNow()
        logos?.shutdown()
        logos = nil
        runner.shutdown()
        library.close()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
        todoWindow?.close()
        todoWindow = nil
    }

    @objc private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더 사용"
        panel.message = "메모(md 파일)를 모아 둘 폴더를 고르세요. 옵시디언 보관함도 그대로 쓸 수 있어요."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeLibrary()
        openLibrary(at: url)
    }

    @objc private func addWorkspace() {
        workspaces.chooseAndAdd()
    }

    @objc private func revealNotesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    /// 테스트용: 작업 폴더 팝업을 일반 창으로 (저장하지 않는 즐겨찾기, 첫 폴더 펼침)
    private var previewWindow: NSWindow?

    private func previewWorkspaces(_ path: String) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "작업 폴더 미리보기"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: WorkspaceBrowser(
            store: WorkspaceStore(previewPaths: [path, NSHomeDirectory()]),
            onInsert: { _ in },
            initiallyExpanded: [path]
        ))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
    }

    // MARK: 설정 창

    private var settingsWindow: NSWindow?

    @objc private func showSettings() {
        openSettings(tab: "general")
    }

    private func openSettings(tab: String) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 470),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Twinkle 설정"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // 메모 폴더가 바뀌었을 수 있어서 열 때마다 내용을 새로
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(
            settings: AppSettings.shared,
            runner: runner,
            workspaces: workspaces,
            notesFolder: library.root,
            onChangeNotesFolder: { [weak self] in
                self?.chooseNotesFolder()
                self?.showSettings()
            },
            tab: tab
        ))
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: 메모 창

    @objc private func openMainNote() {
        openNote(NoteLibrary.mainNotePath, focus: true)
    }

    @objc private func newNote() {
        let path = library.createUntitledNote().relativePath
        openNote(path, focus: true)
        controllers[path]?.selectTitle()
    }

    private func openLink(_ link: String) {
        guard let doc = library.documentForLink(link) else { return }
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
        guard let document = library.documents[path] else { return }

        let state = layout.states[path] ?? WindowState(frame: defaultFrame())
        let controller = NoteWindowController(document: document, state: state, runner: runner, workspaces: workspaces)
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
        library.saveLayout(layout)
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
                library: library,
                runner: runner,
                onOpenNote: { [weak self] in self?.openNote($0, focus: true) },
                onOpenSettings: { [weak self] in self?.showSettings() }
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
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Twinkle")

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
        menu.addItem(withTitle: "메모 폴더 바꾸기…", action: #selector(chooseNotesFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "작업 폴더 추가…", action: #selector(addWorkspace), keyEquivalent: "").target = self
        menu.addItem(withTitle: "메모 폴더 열기", action: #selector(revealNotesFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "설정…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Twinkle 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        appMenu.addItem(withTitle: "설정…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Twinkle 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

// 앱 설정(즐겨찾기 등)을 읽는 객체들이 만들어지기 전에 예전 이름의 설정부터 가져옴
AppPaths.migrateOldDefaults()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
