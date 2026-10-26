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
        // 테스트용: 메인 메모를 열자마자 활성화해서 키 입력을 받게
        if arguments.contains("--focus") {
            openNote(NoteLibrary.mainNotePath, focus: true)
            controllers[NoteLibrary.mainNotePath]?.focusEditor()
        } else {
            // 위젯처럼 조용히 시작: 포커스는 쓰던 앱에 돌려주고 바탕화면 메모는 뒤로
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    NSApp.deactivate()
                    self?.controllers.values.forEach { $0.sendToBackIfDesktop() }
                }
            }
        }
        // 테스트용: 커서 자리에 한글 조합 중인 글자를 만들고(입력기 흉내) 1초 뒤 커서 섹션의 제목을 접음
        if let index = arguments.firstIndex(of: "--debug-ime"), arguments.indices.contains(index + 1) {
            let composing = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let textView = self?.controllers[NoteLibrary.mainNotePath]?.window?.firstResponder as? MarkdownTextView else {
                        NSLog("TWDEBUG no text view focused"); return
                    }
                    textView.setMarkedText(composing, selectedRange: NSRange(location: composing.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    NSLog("TWDEBUG marked=\(textView.hasMarkedText()) range=\(textView.markedRange())")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated {
                            textView.foldHeading(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                MainActor.assumeIsolated {
                                    NSLog("TWDEBUG after fold marked=\(textView.hasMarkedText()) sel=\(textView.selectedRange()) text=\(textView.string.replacingOccurrences(of: "\n", with: "⏎"))")
                                }
                            }
                        }
                    }
                }
            }
        }
        // 테스트용: 메모 모아보기를 일반 창으로 (테스트 앱의 메뉴 막대 아이콘은 자리가 없어 접혀 있을 수 있어서)
        if arguments.contains("--show-grid") {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "모아보기 미리보기"
            let hosting = NSHostingController(rootView: NoteGridView(
                library: library, runner: runner, openPaths: Set(controllers.keys),
                colorFor: { [weak self] in self?.controllers[$0]?.appearance.color ?? self?.layout.states[$0]?.color ?? .yellow },
                onOpen: { _ in }, onCloseNote: { _ in }, onTrash: { _ in }, onNew: {}, onSettings: {}
            ))
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
        }
        // 테스트용: 2초 뒤 메인 메모에서 본문에 글자가 든 할 일의 스레드 열기
        if let index = arguments.firstIndex(of: "--show-thread"), arguments.indices.contains(index + 1) {
            let needle = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.controllers[NoteLibrary.mainNotePath]?.debugOpenThread(containing: needle) }
            }
        }
        // 테스트용: 가짜 작업 기록(말 + 도구 여러 개)으로 Claude 말풍선 열기
        if arguments.contains("--debug-history"), let todo = library.todos.first {
            let job = AgentJob(kind: .claude, todo: todo, logURL: AppPaths.logs.appendingPathComponent("preview.jsonl"), workdir: library.root, isResume: false)
            for text in ["💬 슬라이드를 이미지로 렌더링해서 확인할게요.", "🔧 Bash  cat > /tmp/gseek/grid.py", "🔧 Bash  cd /tmp/gseek/img && python grid.py",
                         "🔧 Read  /tmp/gseek/img/g_src_01.jpg", "🔧 Read  /tmp/gseek/img/g_src_19.jpg", "🔧 Read  /tmp/gseek/img/g_src_25.jpg",
                         "💬 섹션 01에 자리표시 슬라이드가 있고, 02에 중복 슬라이드가 세 장 있어요.", "$ ls -la", "✏️ 파일 수정  notes.md"] {
                job.appendForPreview(text)
            }
            runner.previewFinishedJob(job)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.logos?.openDetails(.claude) }
            }
        }
        // 테스트용: 2초 뒤 로고 말풍선 열기
        if let index = arguments.firstIndex(of: "--show-details"), arguments.indices.contains(index + 1),
           let kind = AgentKind(rawValue: arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.logos?.openDetails(kind) }
            }
        }
        // 테스트용: 첫 줄 끝에서 한 글자씩 타이핑 (실제 입력과 같은 insertText 경로)
        if let index = arguments.firstIndex(of: "--debug-type"), arguments.indices.contains(index + 1) {
            let text = Array(arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let textView = self?.controllers[NoteLibrary.mainNotePath]?.window?.firstResponder as? NSTextView else { return }
                    let firstLine = (textView.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                    textView.setSelectedRange(NSRange(location: NSMaxRange(firstLine) - 1, length: 0))
                    for (offset, character) in text.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset) * 0.03) {
                            MainActor.assumeIsolated { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
                        }
                    }
                }
            }
        }
        // 테스트용: 2초 뒤 메인 메모의 제목 하나를 접거나 펼침 (클릭·단축키와 같은 경로)
        if let index = arguments.firstIndex(of: "--toggle-fold"), arguments.indices.contains(index + 1) {
            let key = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.library.documents[NoteLibrary.mainNotePath]?.toggleFold(key) }
            }
        }
        // 테스트용: 메인 메모에서 댓글이 달린 첫 할 일의 스레드를 일반 창으로
        if arguments.contains("--preview-thread"),
           let document = library.documents[NoteLibrary.mainNotePath],
           let todo = Todo.parse(document.text, docPath: document.relativePath).first(where: { !Todo.thread(in: document.text, todoLine: $0.line).isEmpty }) {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "스레드 미리보기"
            let hosting = NSHostingController(rootView: ThreadView(document: document, runner: runner, library: library, todoBody: todo.body))
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
        }
        if let index = arguments.firstIndex(of: "--preview-workspaces"), arguments.indices.contains(index + 1) {
            previewWorkspaces(arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--show-settings") {
            openSettings(tab: arguments.indices.contains(index + 1) ? arguments[index + 1] : "general")
        }
    }

    /// 에이전트가 일하는 중이면 정말 끌지 물어봄 (작업이 중단되고 다음에 처음부터 다시 함)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runner, !runner.jobs.isEmpty else { return .terminateNow }
        let working = AgentKind.allCases.compactMap { kind in
            runner.jobs[kind].map { "• \(kind.displayName): \(MarkdownPlain.text($0.todo.title))" }
        }
        let alert = NSAlert()
        alert.messageText = "에이전트가 작업 중이에요"
        alert.informativeText = working.joined(separator: "\n") + "\n\n지금 종료하면 작업이 중단되고, 다음에 Twinkle을 켜면 이 할 일을 처음부터 다시 시작해요."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    }

    @objc private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더 사용"
        panel.message = "메모(md 파일)를 모아 둘 폴더를 고르세요."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        closeLibrary()
        openLibrary(at: url)
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
        controller.onOpenTodo = { [weak self] todo in
            self?.openNote(todo.docPath, focus: true)
            self?.controllers[todo.docPath]?.reveal(todoBody: todo.body)
        }
        controller.onNew = { [weak self] in self?.newNote() }
        controller.onClose = { [weak self] controller in
            self?.controllers[controller.note.relativePath] = nil
            self?.scheduleLayoutSave()
        }
        controllers[path] = controller
        controller.showWindow(nil)
        if !focus { controller.sendToBackIfDesktop() }
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
        menu.addItem(.separator())
        let runnerItem = menu.addItem(withTitle: "에이전트 자동 실행", action: #selector(toggleRunner), keyEquivalent: "")
        runnerItem.target = self
        runnerMenuItem = runnerItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Twinkle 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
        // 왼쪽 클릭은 메모 모아보기, 오른쪽 클릭은 메뉴
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private var statusMenu: NSMenu?
    private var gridPopover: NSPopover?

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            gridPopover?.close()
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            toggleNoteGrid(sender)
        }
    }

    /// 메모 모아보기 그리드. 열 때마다 새로 만들어 지금 열려 있는 메모·색을 반영
    private func toggleNoteGrid(_ button: NSStatusBarButton) {
        if let popover = gridPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: NoteGridView(
            library: library,
            runner: runner,
            openPaths: Set(controllers.keys),
            colorFor: { [weak self] path in
                self?.controllers[path]?.appearance.color ?? self?.layout.states[path]?.color ?? .yellow
            },
            onOpen: { [weak self] path in
                self?.gridPopover?.close()
                self?.openNote(path, focus: true)
            },
            onCloseNote: { [weak self] path in
                self?.gridPopover?.close()
                self?.controllers[path]?.closeNote()
            },
            onTrash: { [weak self] path in self?.trashNote(path) },
            onNew: { [weak self] in
                self?.gridPopover?.close()
                self?.newNote()
            },
            onSettings: { [weak self] in
                self?.gridPopover?.close()
                self?.showSettings()
            }
        ))
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        gridPopover = popover
    }

    /// 메모 파일을 휴지통으로 (확인 후). 화면에 떠 있으면 먼저 닫음
    private func trashNote(_ path: String) {
        guard let document = library.documents[path] else { return }
        let alert = NSAlert()
        alert.messageText = "‘\(document.title)’ 메모를 휴지통으로 옮길까요?"
        alert.informativeText = "Finder 휴지통에서 되살릴 수 있어요."
        alert.addButton(withTitle: "휴지통으로")
        alert.addButton(withTitle: "취소")
        gridPopover?.close()
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controllers[path]?.closeNote()
        NSWorkspace.shared.recycle([document.url]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.library.scan() } }
        }
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
        editMenu.addItem(.separator())
        let fold = editMenu.addItem(withTitle: "제목 접기", action: #selector(MarkdownTextView.foldHeading(_:)), keyEquivalent: "[")
        fold.keyEquivalentModifierMask = [.command, .option]
        let unfold = editMenu.addItem(withTitle: "제목 펼치기", action: #selector(MarkdownTextView.unfoldHeading(_:)), keyEquivalent: "]")
        unfold.keyEquivalentModifierMask = [.command, .option]
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
