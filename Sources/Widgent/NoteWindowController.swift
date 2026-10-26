import AppKit
import Combine
import SwiftUI

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let note: NoteDocument
    let appearance: NoteAppearance
    var onLayoutChange: (@MainActor () -> Void)?
    var onOpenLink: (@MainActor (String) -> Void)?
    var onNew: (@MainActor () -> Void)?
    var onShowTodos: (@MainActor () -> Void)?
    var onClose: (@MainActor (NoteWindowController) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    var state: WindowState {
        WindowState(frame: window?.frame ?? .zero, color: appearance.color, level: appearance.level)
    }

    init(document: NoteDocument, state: WindowState, runner: AgentRunner) {
        self.note = document
        appearance = NoteAppearance(color: state.color, level: state.level)

        let window = NSWindow(
            contentRect: state.frame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 180, height: 120)
        // 메모지는 밝은 색이라 다크 모드에서도 글자를 검정으로 유지
        window.appearance = NSAppearance(named: .aqua)

        super.init(window: window)

        let hosting = NSHostingView(rootView: NoteView(
            document: document,
            appearance: appearance,
            runner: runner,
            onOpenLink: { [weak self] in self?.onOpenLink?($0) },
            onNew: { [weak self] in self?.onNew?() },
            onShowTodos: { [weak self] in self?.onShowTodos?() },
            onToggleLevel: { [weak self] in self?.toggleLevel() },
            onClose: { [weak self] in self?.closeNote() }
        ))
        // SwiftUI 콘텐츠 크기가 창 크기를 바꾸지 않도록
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(state.frame, display: false)
        window.delegate = self

        appearance.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onLayoutChange?() }
            .store(in: &cancellables)
        applyLevel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func toggleLevel() {
        appearance.level = appearance.level == .desktop ? .floating : .desktop
        applyLevel()
    }

    private func applyLevel() {
        guard let window else { return }
        switch appearance.level {
        case .desktop:
            // 바탕화면 아이콘 바로 위: 일반 창들보다 아래에 깔리고 Mission Control에도 고정
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    private func closeNote() {
        note.save()
        window?.close()
        onClose?(self)
    }

    func windowDidMove(_ notification: Notification) { onLayoutChange?() }
    func windowDidResize(_ notification: Notification) { onLayoutChange?() }
}
