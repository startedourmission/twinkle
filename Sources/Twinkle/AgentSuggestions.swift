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

    private static let initials: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    /// 완성형 한글 음절은 초성으로, 나머지는 그대로 (ㄷ → 디자인 찾기)
    static func choseong(of text: String) -> String {
        String(text.map { character -> Character in
            guard let scalar = character.unicodeScalars.first, (0xAC00...0xD7A3).contains(scalar.value) else { return character }
            return initials[Int((scalar.value - 0xAC00) / 588)]
        })
    }
}

/// 자동완성 후보: `@`는 에이전트, `[[`는 메모
enum SuggestionItem: Hashable {
    case agent(AgentKind)
    case note(title: String, path: String)
    /// 맞는 메모가 없을 때: 그 이름으로 링크를 넣음 (누르면 새 메모가 만들어짐)
    case create(String)
}

@MainActor
final class AgentSuggestionModel: ObservableObject {
    @Published var items: [SuggestionItem] = []
    @Published var selected = 0
}

/// `@`나 `[[`를 치면 커서 아래에 뜨는 목록. 글자를 미리 넣지 않아서 지우기를 방해하지 않음
@MainActor
final class AgentSuggestionPopup {
    /// 지금 바꿔 넣을 `@글자`나 `[[글자` 범위
    private(set) var range: NSRange?
    var onAccept: ((SuggestionItem, NSRange) -> Void)?

    private let model = AgentSuggestionModel()
    private var panel: NSPanel?
    /// Esc로 닫은 위치. 같은 자리에서는 다시 띄우지 않음
    private var dismissedLocation: Int?

    nonisolated(unsafe) private static let mention = /(?:^|\s)@([A-Za-zㄱ-ㅎㅏ-ㅣ]*)$/
    nonisolated(unsafe) private static let wikiLink = /\[\[([^\[\]\n]*)$/

    var isVisible: Bool { panel?.isVisible == true && range != nil }

    /// 커서 앞이 `@글자`나 `[[글자`면 목록을 띄우고, 아니면 닫음
    /// excluding: 지금 쓰고 있는 메모 (자기 자신에 링크하지 않게)
    func update(in textView: NSTextView, library: NoteLibrary?, excluding: String? = nil) {
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        guard selection.length == 0, textView.window?.firstResponder === textView else { return hide() }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))

        let items: [SuggestionItem]
        let location: Int
        if let match = prefix.firstMatch(of: Self.wikiLink), let library {
            let query = String(match.1).trimmingCharacters(in: .whitespaces)
            location = selection.location - match.0.utf16.count
            items = Self.notes(matching: query, in: library, excluding: excluding)
            range = NSRange(location: location, length: match.0.utf16.count)
        } else if let match = prefix.firstMatch(of: Self.mention) {
            let typed = String(match.1)
            let latin = KoreanKeyboard.latin(typed).lowercased()
            let agents = AgentKind.allCases.filter { $0.rawValue.hasPrefix(latin) }
            // 이미 다 쳤으면(@claude) 굳이 띄우지 않음
            items = agents.count == 1 && agents[0].rawValue == latin ? [] : agents.map { .agent($0) }
            location = selection.location - typed.utf16.count - 1
            range = NSRange(location: location, length: typed.utf16.count + 1)
        } else {
            return hide()
        }
        guard !items.isEmpty, dismissedLocation != location else { return hide() }
        if dismissedLocation != nil, dismissedLocation != location { dismissedLocation = nil }

        if model.items != items {
            model.items = items
            model.selected = 0
        }
        show(below: textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil), in: textView)
    }

    /// 제목·초성으로 찾은 메모 (최근 수정 순, 최대 7개) + 정확히 같은 제목이 없으면 "새 메모"
    private static func notes(matching query: String, in library: NoteLibrary, excluding: String?) -> [SuggestionItem] {
        let documents = library.documents.values.filter { $0.relativePath != excluding }.sorted { ($0.diskModified ?? .distantPast) > ($1.diskModified ?? .distantPast) }
        let matched = documents.filter { doc in
            query.isEmpty
                || doc.title.localizedCaseInsensitiveContains(query)
                || doc.name.localizedCaseInsensitiveContains(query)
                || KoreanKeyboard.choseong(of: doc.title).contains(query)
        }
        var items = matched.prefix(7).map { SuggestionItem.note(title: $0.title, path: $0.relativePath) }
        if !query.isEmpty, !documents.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
            items.append(.create(query))
        }
        return items
    }

    func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    func accept() {
        guard let range, model.items.indices.contains(model.selected) else { return }
        let item = model.items[model.selected]
        hide()
        onAccept?(item, range)
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
        let size = CGSize(width: 260, height: CGFloat(model.items.count) * 40 + 10)
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
            ForEach(Array(model.items.enumerated()), id: \.element) { index, item in
                row(item, selected: index == model.selected)
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

    @ViewBuilder
    private func icon(_ item: SuggestionItem) -> some View {
        switch item {
        case .agent(let kind):
            AgentBadge(kind: kind, size: 24)
        case .note:
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.35)))
        case .create:
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        }
    }

    private func texts(_ item: SuggestionItem) -> (String, String, Bool) {
        switch item {
        case .agent(let kind):
            let enabled = AppSettings.shared.settings(for: kind).enabled
            return (kind.displayName, enabled ? kind.tag : "\(kind.tag) · 꺼짐", enabled)
        case .note(let title, let path):
            return (title, path, true)
        case .create(let name):
            return ("새 메모: \(name)", "링크를 누르면 만들어져요", true)
        }
    }

    private func row(_ item: SuggestionItem, selected: Bool) -> some View {
        let (title, subtitle, enabled) = texts(item)
        return HStack(spacing: 9) {
            icon(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, design: item.isAgent ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

private extension SuggestionItem {
    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}
