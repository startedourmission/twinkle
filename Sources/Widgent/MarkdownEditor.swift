import AppKit
import SwiftUI

/// NSTextView 기반 마크다운 편집기. 원문은 그대로 두고 글자 모양만 입혀서 보여줌
struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var document: NoteDocument
    var onOpenLink: (String) -> Void
    var onTextViewReady: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.font = MarkdownStyler.baseFont
        textView.textColor = MarkdownStyler.textColor
        textView.insertionPointColor = .black
        // 링크 색은 우리가 직접 입히고, 커서만 손가락으로
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]

        textView.string = document.text
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        MarkdownStyler.apply(to: textView.textStorage!)
        context.coordinator.textView = textView
        onTextViewReady(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, textView.string != document.text else { return }
        // 에이전트나 다른 프로그램이 바꾼 내용 반영. 커서 위치는 최대한 유지
        let selection = textView.selectedRange()
        context.coordinator.isApplyingExternalChange = true
        textView.string = document.text
        context.coordinator.isApplyingExternalChange = false
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var isApplyingExternalChange = false

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateEditingLine()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.document.editingLine = nil
        }

        private func updateEditingLine() {
            guard let textView, textView.window?.firstResponder === textView else {
                parent.document.editingLine = nil
                return
            }
            let location = min(textView.selectedRange().location, (textView.string as NSString).length)
            let prefix = (textView.string as NSString).substring(to: location)
            parent.document.editingLine = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange, let textView else { return }
            if !textView.hasMarkedText(), let storage = textView.textStorage {
                MarkdownStyler.apply(to: storage)
            }
            parent.document.text = textView.string
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            // 텍스트 뷰의 저장소라 항상 메인 스레드에서 불림
            nonisolated(unsafe) let textStorage = textStorage
            MainActor.assumeIsolated {
                // 한글 조합 중에 속성을 갈아엎으면 입력기가 깨짐. 조합이 끝나면 다시 불림
                guard textView?.hasMarkedText() != true else { return }
                MarkdownStyler.apply(to: textStorage)
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
                  url.scheme == "widgent"
            else { return false }
            let value = url.path.removingPercentEncoding.map { String($0.dropFirst()) } ?? ""
            switch url.host {
            case "toggle":
                if let line = Int(value), let updated = Todo.toggling(parent.document.text, line: line) {
                    parent.document.text = updated
                }
            case "open":
                parent.onOpenLink(value)
            default:
                return false
            }
            return true
        }
    }
}

@MainActor
enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let textColor = NSColor(white: 0.12, alpha: 1)
    static let mutedColor = NSColor(white: 0.45, alpha: 1)
    static let linkColor = NSColor(red: 0.10, green: 0.38, blue: 0.85, alpha: 1)

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})\\s+.*$", options: .anchorsMatchLines)
    private static let checkbox = try! NSRegularExpression(pattern: "^(\\s*[-*+] )(\\[(.)\\])( .*)?$", options: .anchorsMatchLines)
    private static let resultLine = try! NSRegularExpression(pattern: "^\\s*- ↳ .*$", options: .anchorsMatchLines)
    private static let wikiLink = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]")
    private static let agentTag = try! NSRegularExpression(pattern: "@(claude|codex|grok)\\b", options: .caseInsensitive)
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    static func apply(to storage: NSTextStorage) {
        let string = storage.string as NSString
        let full = NSRange(location: 0, length: string.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraph], range: full)

        heading.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            let level = match.range(at: 1).length
            let size: CGFloat = [22, 18, 16, 15, 14, 14][level - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: match.range)
            storage.addAttribute(.foregroundColor, value: mutedColor, range: match.range(at: 1))
        }

        // 체크박스 줄 번호를 알아야 클릭 시 토글할 수 있음
        var lineStarts: [Int] = [0]
        string.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lineStarts.append(enclosing.upperBound)
        }
        func lineNumber(at location: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
            }
            return low
        }

        checkbox.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            let box = match.range(at: 2)
            let state = TodoState(mark: Character(string.substring(with: match.range(at: 3))))
            let line = lineNumber(at: match.range.location)
            storage.addAttributes([
                .link: URL(string: "widgent://toggle/\(line)")!,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color(for: state),
            ], range: box)
            let body = match.range(at: 4)
            if state == .done, body.location != NSNotFound {
                storage.addAttributes([.foregroundColor: mutedColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: body)
            }
        }

        resultLine.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            storage.addAttributes([.foregroundColor: mutedColor, .font: NSFont.systemFont(ofSize: 12)], range: match.range)
        }

        bold.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: match.range)
        }

        code.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .backgroundColor: NSColor.black.withAlphaComponent(0.06),
            ], range: match.range)
        }

        wikiLink.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            let target = string.substring(with: match.range(at: 1))
            guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "widgent://open/\(encoded)")
            else { return }
            storage.addAttributes([.link: url, .foregroundColor: linkColor], range: match.range)
        }

        agentTag.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match,
                  let kind = AgentKind(rawValue: string.substring(with: match.range(at: 1)).lowercased())
            else { return }
            storage.addAttributes([
                .foregroundColor: kind.color,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            ], range: match.range)
        }

        storage.endEditing()
    }

    static func color(for state: TodoState) -> NSColor {
        switch state {
        case .open: textColor
        case .doing: NSColor.systemOrange
        case .done: NSColor.systemGreen
        case .failed: NSColor.systemRed
        }
    }
}
