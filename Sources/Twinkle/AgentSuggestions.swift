import AppKit
import SwiftUI

/// 한글 자판 상태에서 친 자모를 영문 자판 글자로 (ㄴ → s). 자판을 안 바꾸고 쳐도 찾게 하려고
enum KoreanKeyboard {
    private static let qwerty: [Character: Character] = [
        "ㅂ": "q", "ㅈ": "w", "ㄷ": "e", "ㄱ": "r", "ㅅ": "t", "ㅛ": "y", "ㅕ": "u", "ㅑ": "i", "ㅐ": "o", "ㅔ": "p",
        "ㅁ": "a", "ㄴ": "s", "ㅇ": "d", "ㄹ": "f", "ㅎ": "g", "ㅗ": "h", "ㅓ": "j", "ㅏ": "k", "ㅣ": "l",
        "ㅋ": "z", "ㅌ": "x", "ㅊ": "c", "ㅍ": "v", "ㅠ": "b", "ㅜ": "n", "ㅡ": "m",
        "ㅃ": "q", "ㅉ": "w", "ㄸ": "e", "ㄲ": "r", "ㅆ": "t", "ㅒ": "o", "ㅖ": "p",
    ]

    static func latin(_ text: String) -> String {
        String(text.map { qwerty[$0] ?? $0 })
    }
}

@MainActor
final class AgentSuggestionModel: ObservableObject {
    @Published var items: [AgentKind] = []
    @Published var selected = 0
}

/// `@`를 치면 커서 아래에 뜨는 에이전트 목록. 글자를 미리 넣지 않아서 지우기를 방해하지 않음
@MainActor
final class AgentSuggestionPopup {
    /// 지금 바꿔 넣을 `@글자` 범위
    private(set) var range: NSRange?
    var onAccept: ((AgentKind, NSRange) -> Void)?

    private let model = AgentSuggestionModel()
    private var panel: NSPanel?
    /// Esc로 닫은 `@` 위치. 같은 자리에서는 다시 띄우지 않음
    private var dismissedLocation: Int?

    nonisolated(unsafe) private static let mention = /(?:^|\s)@([A-Za-zㄱ-ㅎㅏ-ㅣ]*)$/

    var isVisible: Bool { panel?.isVisible == true && range != nil }

    /// 커서 앞이 `@글자`면 목록을 띄우고, 아니면 닫음
    func update(in textView: NSTextView) {
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        guard selection.length == 0, textView.window?.firstResponder === textView else { return hide() }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        guard let match = prefix.firstMatch(of: Self.mention) else { return hide() }

        let typed = String(match.1)
        let latin = KoreanKeyboard.latin(typed).lowercased()
        let items = AgentKind.allCases.filter { $0.rawValue.hasPrefix(latin) }
        let location = selection.location - typed.utf16.count - 1
        // 이미 다 쳤으면(@claude) 굳이 띄우지 않음
        guard !items.isEmpty, !(items.count == 1 && items[0].rawValue == latin), dismissedLocation != location else { return hide() }
        if dismissedLocation != nil, dismissedLocation != location { dismissedLocation = nil }

        range = NSRange(location: location, length: typed.utf16.count + 1)
        if model.items != items {
            model.items = items
            model.selected = 0
        }
        show(below: textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil), in: textView)
    }

    func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    func accept() {
        guard let range, model.items.indices.contains(model.selected) else { return }
        let kind = model.items[model.selected]
        hide()
        onAccept?(kind, range)
    }

    func dismiss() {
        dismissedLocation = range?.location
        hide()
    }

    func hide() {
        range = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(below caret: NSRect, in textView: NSTextView) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = textView.window?.appearance
        let size = CGSize(width: 240, height: CGFloat(model.items.count) * 40 + 10)
        var origin = CGPoint(x: caret.minX - 10, y: caret.minY - size.height - 4)
        // 화면 아래가 모자라면 커서 위로
        if let screen = textView.window?.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = caret.maxY + 4
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if panel.parent == nil, let window = textView.window {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = FirstClickHostingView(rootView: AgentSuggestionList(model: model) { [weak self] index in
            self?.model.selected = index
            self?.accept()
        })
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

/// 비활성 패널이어도 첫 클릭을 바로 받음
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AgentSuggestionList: View {
    @ObservedObject var model: AgentSuggestionModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.element) { index, kind in
                row(kind, selected: index == model.selected)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(index) }
                    .onHover { if $0 { model.selected = index } }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }

    private func row(_ kind: AgentKind, selected: Bool) -> some View {
        let enabled = AppSettings.shared.settings(for: kind).enabled
        return HStack(spacing: 9) {
            AgentBadge(kind: kind, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(enabled ? kind.tag : "\(kind.tag) · 꺼짐")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
        )
    }
}
