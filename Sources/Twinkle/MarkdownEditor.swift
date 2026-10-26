import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// 접힌 댓글처럼 화면에서 감출 글자
    static let twinkleHidden = NSAttributedString.Key("twinkleHidden")
    /// 잘린 댓글 끝에 "…"로 바꿔 그릴 글자
    static let twinkleEllipsis = NSAttributedString.Key("twinkleEllipsis")
    /// 접을 수 있는 제목 줄의 첫 글자 (값: 제목 키)
    static let twinkleHeading = NSAttributedString.Key("twinkleHeading")
    /// 지금 접혀 있는 제목
    static let twinkleFolded = NSAttributedString.Key("twinkleFolded")
}

/// NSTextView 기반 마크다운 편집기. 원문은 그대로 두고 글자 모양만 입혀서 보여줌
struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var document: NoteDocument
    var onOpenLink: (String) -> Void
    var onTextViewReady: (NSTextView) -> Void = { _ in }
    /// 댓글 줄 클릭: todo 줄 번호, 텍스트 뷰 안에서 그 댓글의 위치
    var onOpenThread: (Int, NSRect) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 댓글 접기에 NSLayoutManager(TextKit 1)의 글리프 숨기기를 써서 직접 구성
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(FoldingLayoutManager())
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        // 제목 접기 ▾/▸ 자리는 문단 들여쓰기로 글자 영역 안에 만듦 (글자 영역 밖은 그려도 잘림)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.font = MarkdownStyler.baseFont
        textView.textColor = MarkdownStyler.textColor
        textView.insertionPointColor = .black
        // 링크 색은 우리가 직접 입히고, 커서만 손가락으로
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]

        textView.string = document.text
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.onToggleFold = { [weak document] key in document?.toggleFold(key) }
        MarkdownStyler.apply(to: textView.textStorage!, folded: document.foldedHeadings)
        context.coordinator.appliedFolds = document.foldedHeadings
        context.coordinator.textView = textView
        onTextViewReady(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let textView = context.coordinator.textView, context.coordinator.appliedFolds != document.foldedHeadings {
            context.coordinator.applyFolds(in: textView)
        }
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
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, @preconcurrency NSLayoutManagerDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var isApplyingExternalChange = false
        /// 마지막으로 그린 접힘 상태
        var appliedFolds: Set<String> = []
        /// `- [` 자동완성 직후 사용자가 습관대로 치는 " ] "를 삼키기 위한 기대 문자들
        private var swallow: (location: Int, characters: [String])?

        private static let todoLine = /^(\s*)([-*+]) \[.\] ?(.*)$/
        private static let bulletLine = /^(\s*)([-*+]) (?!↳)(.*)$/
        private static let agentPrefix = /(^|\s)@([a-zA-Z]*)$/

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        /// 제목을 접거나 펼친 뒤 다시 그림. 커서가 숨은 곳에 있으면 제목 끝으로 옮김
        func applyFolds(in textView: NSTextView) {
            (textView as? MarkdownTextView)?.commitComposition()
            guard let storage = textView.textStorage else { return }
            appliedFolds = parent.document.foldedHeadings
            MarkdownStyler.apply(to: storage, folded: appliedFolds)
            let location = textView.selectedRange().location
            var hiddenRange = NSRange()
            if location < storage.length,
               storage.attribute(.twinkleHidden, at: location, longestEffectiveRange: &hiddenRange, in: NSRange(location: 0, length: storage.length)) != nil {
                textView.setSelectedRange(NSRange(location: hiddenRange.location, length: 0))
            }
            textView.needsDisplay = true
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
                MarkdownStyler.apply(to: storage, folded: parent.document.foldedHeadings)
            }
            parent.document.text = textView.string
            suggestAgentIfNeeded(in: textView)
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
                MarkdownStyler.apply(to: textStorage, folded: parent.document.foldedHeadings)
            }
        }

        // MARK: 자동완성

        /// 커서 앞의 줄 내용
        private func linePrefix(in textView: NSTextView, at location: Int) -> String {
            let string = textView.string as NSString
            let lineStart = string.lineRange(for: NSRange(location: location, length: 0)).location
            return string.substring(with: NSRange(location: lineStart, length: location - lineStart))
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, !textView.hasMarkedText(), range.length == 0 else {
                swallow = nil
                return true
            }

            // "- [ ] " 직후 습관적으로 치는 " ", "]", " "는 이미 있으니 삼킴
            if var pending = swallow, pending.location == range.location, pending.characters.first == text {
                pending.characters.removeFirst()
                swallow = pending.characters.isEmpty ? nil : pending
                return false
            }
            swallow = nil

            // "- [" → "- [ ] "
            if text == "[", linePrefix(in: textView, at: range.location).wholeMatch(of: #/\s*[-*+] /#) != nil {
                textView.insertText("[ ] ", replacementRange: range)
                swallow = (range.location + 4, [" ", "]", " "])
                return false
            }
            return true
        }

        /// "@c"처럼 치면 에이전트 이름 후보를 띄움
        private func suggestAgentIfNeeded(in textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let location = textView.selectedRange().location
            guard let match = linePrefix(in: textView, at: location).firstMatch(of: Self.agentPrefix),
                  match.2.count == 1,
                  AgentKind.allCases.contains(where: { $0.rawValue.hasPrefix(match.2.lowercased()) })
            else { return }
            textView.complete(nil)
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let string = textView.string as NSString
            let partial = string.substring(with: charRange)
            let isAgent = partial.hasPrefix("@") || (charRange.location > 0 && string.substring(with: NSRange(location: charRange.location - 1, length: 1)) == "@")
            guard isAgent else { return words }
            let typed = partial.hasPrefix("@") ? String(partial.dropFirst()) : partial
            let names = AgentKind.allCases.map(\.rawValue).filter { $0.hasPrefix(typed.lowercased()) }
            index?.pointee = 0
            return names.map { partial.hasPrefix("@") ? "@\($0) " : "\($0) " }
        }

        /// 엔터: todo/목록 줄이면 다음 줄에 같은 머리를 이어 줌. 빈 항목에서 엔터면 목록 끝내기
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let location = textView.selectedRange().location
            let string = textView.string as NSString
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            let prefix = linePrefix(in: textView, at: location)

            let continuation: (indent: String, head: String, rest: String)?
            if let match = prefix.wholeMatch(of: Self.todoLine) {
                continuation = (String(match.1), "\(match.2) [ ] ", String(match.3))
            } else if let match = prefix.wholeMatch(of: Self.bulletLine) {
                continuation = (String(match.1), "\(match.2) ", String(match.3))
            } else {
                continuation = nil
            }
            guard let continuation else { return false }

            if continuation.rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // 내용 없는 항목에서 엔터 → 머리만 지우고 목록 끝
                let headRange = NSRange(location: lineRange.location, length: location - lineRange.location)
                textView.insertText(continuation.indent, replacementRange: headRange)
            } else {
                textView.insertText("\n" + continuation.indent + continuation.head, replacementRange: textView.selectedRange())
            }
            return true
        }

        // MARK: 링크 클릭

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
                  url.scheme == "twinkle"
            else { return false }
            let value = url.path.removingPercentEncoding.map { String($0.dropFirst()) } ?? ""
            switch url.host {
            case "toggle":
                if let line = Int(value), let updated = Todo.toggling(parent.document.text, line: line) {
                    parent.document.text = updated
                }
            case "open":
                parent.onOpenLink(value)
            case "thread":
                guard let line = Int(value), let layoutManager = textView.layoutManager, let container = textView.textContainer else { return true }
                let lineRange = (textView.string as NSString).lineRange(for: NSRange(location: charIndex, length: 0))
                let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += textView.textContainerOrigin.x
                rect.origin.y += textView.textContainerOrigin.y
                parent.onOpenThread(line, rect)
            default:
                return false
            }
            return true
        }

        // MARK: 댓글 접기 (글리프 숨기기)

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
            var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
            var changed = false
            for i in 0..<count {
                let index = characterIndexes[i]
                guard index < storage.length else { continue }
                if storage.attribute(.twinkleHidden, at: index, effectiveRange: nil) != nil {
                    newProperties[i] = .null
                    changed = true
                } else if storage.attribute(.twinkleEllipsis, at: index, effectiveRange: nil) != nil {
                    var glyph: CGGlyph = 0
                    var ellipsis: UniChar = 0x2026
                    if CTFontGetGlyphsForCharacters(font as CTFont, &ellipsis, &glyph, 1) {
                        newGlyphs[i] = glyph
                        newProperties[i] = []
                        changed = true
                    }
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return count
        }

        /// 숨긴 줄바꿈은 줄을 넘기지 않게
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldUse action: NSLayoutManager.ControlCharacterAction,
            forControlCharacterAt charIndex: Int
        ) -> NSLayoutManager.ControlCharacterAction {
            guard let storage = layoutManager.textStorage, charIndex < storage.length,
                  storage.attribute(.twinkleHidden, at: charIndex, effectiveRange: nil) != nil
            else { return action }
            return .zeroAdvancement
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
    private static let wikiLink = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]")
    private static let agentTag = try! NSRegularExpression(pattern: "@(claude|codex|grok)\\b", options: .caseInsensitive)
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    static func apply(to storage: NSTextStorage, folded: Set<String> = []) {
        let string = storage.string as NSString
        let full = NSRange(location: 0, length: string.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.firstLineHeadIndent = MarkdownTextView.gutterWidth
        paragraph.headIndent = MarkdownTextView.gutterWidth

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraph], range: full)

        heading.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            let level = match.range(at: 1).length
            let size: CGFloat = [22, 18, 16, 15, 14, 14][level - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: match.range)
            storage.addAttribute(.foregroundColor, value: mutedColor, range: match.range(at: 1))
            // 제목 위아래는 조금 띄움 (맨 윗줄 제목은 위쪽만 덜)
            let spaced = paragraph.mutableCopy() as! NSMutableParagraphStyle
            spaced.paragraphSpacingBefore = match.range.location == 0 ? 4 : 8
            spaced.paragraphSpacing = 3
            storage.addAttribute(.paragraphStyle, value: spaced, range: match.range)
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
                .link: URL(string: "twinkle://toggle/\(line)")!,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color(for: state),
            ], range: box)
            let body = match.range(at: 4)
            if state == .done, body.location != NSNotFound {
                storage.addAttributes([.foregroundColor: mutedColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: body)
            }
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
                  let url = URL(string: "twinkle://open/\(encoded)")
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

        foldComments(in: storage, lineStarts: lineStarts)
        foldHeadings(in: storage, lineStarts: lineStarts, folded: folded)
        // 시스템 폰트에 없는 글자(한글, ↳ 등)에 대체 폰트를 다시 지정. 안 하면 TextKit 1에서 글자가 사라짐
        storage.fixAttributes(in: full)

        storage.endEditing()
        // 숨김 속성이 바뀌었으니 글리프를 다시 만들게 함
        for layoutManager in storage.layoutManagers {
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    // MARK: 제목 접기

    nonisolated(unsafe) private static let headingLine = /^(#{1,6})\s+(.*)$/

    /// 같은 단계·같은 글자의 제목은 같이 접힘
    static func headingKey(level: Int, title: String) -> String {
        "\(level)|\(title.trimmingCharacters(in: .whitespaces))"
    }

    /// 제목 줄 첫 글자에 접기 정보를 달고, 접힌 제목이면 다음 같은 단계(또는 상위) 제목 직전까지 숨김.
    /// 맨 윗줄은 메모 제목이라 접지 않음
    private static func foldHeadings(in storage: NSTextStorage, lineStarts: [Int], folded: Set<String>) {
        let string = storage.string
        let length = (string as NSString).length
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let headings: [(line: Int, level: Int, key: String)] = lines.enumerated().compactMap { index, line in
            guard let match = line.wholeMatch(of: headingLine) else { return nil }
            return (index, match.1.count, headingKey(level: match.1.count, title: String(match.2)))
        }

        for (position, heading) in headings.enumerated() where heading.line > 0 && lineStarts.indices.contains(heading.line) {
            let end = headings[(position + 1)...].first { $0.level <= heading.level }?.line ?? lines.count
            let body = lines[(heading.line + 1)..<end]
            guard body.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }

            let isFolded = folded.contains(heading.key)
            storage.addAttribute(.twinkleHeading, value: heading.key, range: NSRange(location: lineStarts[heading.line], length: 1))
            if isFolded {
                storage.addAttribute(.twinkleFolded, value: true, range: NSRange(location: lineStarts[heading.line], length: 1))
                // 제목 줄 끝 줄바꿈부터 다음 제목 앞 줄바꿈 직전까지
                let start = lineStarts[heading.line + 1] - 1
                let stop = end < lines.count && lineStarts.indices.contains(end) ? lineStarts[end] - 1 : length
                if stop > start {
                    storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: start, length: stop - start))
                }
            }
        }
    }

    /// 접힌 댓글에서 보여줄 최대 글자 수
    private static let collapsedLength = 46

    /// todo 아래 댓글 스레드는 마지막 한 줄만 짧게 보여주고 나머지는 숨김. 클릭하면 스레드 팝오버
    private static func foldComments(in storage: NSTextStorage, lineStarts: [Int]) {
        let string = storage.string as NSString
        let text = storage.string
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            guard lines[index].wholeMatch(of: Todo.lineRegex) != nil else {
                index += 1
                continue
            }
            let todoLine = index
            var commentLines: [Int] = []
            var next = index + 1
            while next < lines.count, lines[next].wholeMatch(of: Todo.commentRegex) != nil {
                commentLines.append(next)
                next += 1
            }
            index = next
            guard let last = commentLines.last, lineStarts.indices.contains(last) else { continue }

            // 마지막 댓글을 뺀 나머지는 앞 줄바꿈까지 통째로 숨김
            for line in commentLines.dropLast() {
                let start = lineStarts[line]
                let length = (lines[line] as Substring).utf16.count
                storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: start - 1, length: length + 1))
            }

            let start = lineStarts[last]
            let lineText = String(lines[last])
            let lineLength = lineText.utf16.count
            let lineRange = NSRange(location: start, length: lineLength)
            guard let match = lineText.wholeMatch(of: Todo.commentRegex) else { continue }

            var shown = String(match.3)
            if let meta = shown.firstMatch(of: Todo.metaRegex) { shown.removeSubrange(meta.range) }
            let contentStart = start + lineText.utf16.count - String(match.3).utf16.count
            let author = String(match.2)
            let agent = AgentKind(rawValue: author)

            storage.addAttributes([
                .foregroundColor: agent.map { $0.color.blended(withFraction: 0.35, of: mutedColor) ?? mutedColor } ?? mutedColor,
                .font: NSFont.systemFont(ofSize: 12),
                .link: URL(string: "twinkle://thread/\(todoLine)")!,
            ], range: lineRange)
            let authorRange = NSRange(location: start + lineText.utf16.count - String(match.3).utf16.count - author.utf16.count - 2, length: author.utf16.count)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: authorRange)

            // 숨은 정보 + 긴 내용은 잘라서 "…"
            let shownLength = shown.utf16.count
            var cut = shownLength
            if shown.count > collapsedLength {
                cut = String(shown.prefix(collapsedLength)).utf16.count
            }
            let hideFrom = contentStart + cut
            let hideLength = start + lineLength - hideFrom
            if hideLength > 0 {
                if cut < shownLength {
                    let ellipsis = string.rangeOfComposedCharacterSequence(at: hideFrom)
                    storage.addAttribute(.twinkleEllipsis, value: true, range: NSRange(location: hideFrom, length: 1))
                    if hideLength > 1 {
                        storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: hideFrom + 1, length: hideLength - 1))
                    }
                    if ellipsis.length > 1 {
                        storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: hideFrom + 1, length: ellipsis.length - 1))
                    }
                } else {
                    storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: hideFrom, length: hideLength))
                }
            }

            // 댓글이 여러 개면 개수 표시: 마지막 줄의 "↳"를 숫자로 대신할 수는 없어서 색으로만 구분
            if commentLines.count > 1 {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: authorRange)
            }
        }
    }

    static func color(for state: TodoState) -> NSColor {
        switch state {
        case .open: textColor
        case .doing: NSColor.systemOrange
        case .done: NSColor.systemGreen
        case .failed: NSColor.systemRed
        case .waiting: NSColor.systemPurple
        }
    }
}

/// 제목 접기 표시 하나: 여백의 ▾/▸ 자리와, 접혔으면 제목 뒤 ⋯ 자리 (텍스트 뷰 좌표)
struct FoldControl {
    let key: String
    let folded: Bool
    let triangle: NSRect
    let pill: NSRect?
}

/// 글자를 그릴 때 제목 접기 표시도 함께 그림 (텍스트 뷰의 draw는 이 macOS에서 화면에 반영되지 않아서)
final class FoldingLayoutManager: NSLayoutManager {
    func foldControls(origin: NSPoint, gutterWidth: CGFloat) -> [FoldControl] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var controls: [FoldControl] = []
        storage.enumerateAttribute(.twinkleHeading, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let key = value as? String else { return }
            let folded = storage.attribute(.twinkleFolded, at: range.location, effectiveRange: nil) != nil
            var line = lineFragmentUsedRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            line.origin.x += origin.x
            line.origin.y += origin.y
            // 줄 조각의 왼쪽 들여쓰기 자리
            var fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            fragment.origin.x += origin.x
            let triangle = NSRect(x: fragment.minX, y: line.minY, width: gutterWidth, height: line.height)

            var pill: NSRect?
            if folded {
                // 제목이 여러 줄이면 마지막 줄 끝에
                let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
                let lastChar = max(lineRange.location, NSMaxRange(lineRange) - 2)
                var last = lineFragmentUsedRect(forGlyphAt: glyphIndexForCharacter(at: lastChar), effectiveRange: nil)
                last.origin.x += origin.x
                last.origin.y += origin.y
                pill = NSRect(x: last.maxX + 4, y: last.midY - 8, width: 20, height: 16)
            }
            controls.append(FoldControl(key: key, folded: folded, triangle: triangle, pill: pill))
        }
        return controls
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        for control in foldControls(origin: origin, gutterWidth: MarkdownTextView.gutterWidth) {
            // 펼침 ▾ / 접힘 ▸ 삼각형 (텍스트 뷰는 위가 0)
            let center = NSPoint(x: control.triangle.midX + 1, y: control.triangle.midY)
            let triangle = NSBezierPath()
            if control.folded {
                triangle.move(to: NSPoint(x: center.x - 2.5, y: center.y - 4))
                triangle.line(to: NSPoint(x: center.x + 3.5, y: center.y))
                triangle.line(to: NSPoint(x: center.x - 2.5, y: center.y + 4))
            } else {
                triangle.move(to: NSPoint(x: center.x - 4, y: center.y - 2.5))
                triangle.line(to: NSPoint(x: center.x + 4, y: center.y - 2.5))
                triangle.line(to: NSPoint(x: center.x, y: center.y + 3.5))
            }
            triangle.close()
            NSColor(white: 0.25, alpha: control.folded ? 0.75 : 0.28).setFill()
            triangle.fill()

            if let pill = control.pill {
                let dots = NSAttributedString(string: "⋯", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor(white: 0.35, alpha: 1),
                ])
                let size = dots.size()
                dots.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
            }
        }
    }
}

/// 제목 접기 ▾/▸와 ⋯ 클릭을 받는 텍스트 뷰 (그리기는 FoldingLayoutManager)
final class MarkdownTextView: NSTextView {
    nonisolated static let gutterWidth: CGFloat = 16
    var onToggleFold: ((String) -> Void)?

    private var foldControls: [FoldControl] {
        (layoutManager as? FoldingLayoutManager)?.foldControls(origin: textContainerOrigin, gutterWidth: Self.gutterWidth) ?? []
    }

    /// 커서가 들어 있는 섹션의 제목 (커서보다 앞에 있는 마지막 접을 수 있는 제목)
    private func headingAtCursor() -> (key: String, folded: Bool)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let cursor = min(selectedRange().location, storage.length - 1)
        var found: (String, Bool)?
        storage.enumerateAttribute(.twinkleHeading, in: NSRange(location: 0, length: cursor + 1)) { value, range, _ in
            guard let key = value as? String else { return }
            found = (key, storage.attribute(.twinkleFolded, at: range.location, effectiveRange: nil) != nil)
        }
        return found
    }

    /// 한글 조합 중인 글자를 확정. 접기 클릭은 텍스트 뷰로 넘기지 않아서 직접 해 줘야
    /// 마지막 글자가 조합 중 하이라이트로 남지 않음
    func commitComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    @objc func foldHeading(_ sender: Any?) {
        commitComposition()
        if let heading = headingAtCursor(), !heading.folded { onToggleFold?(heading.key) }
    }

    @objc func unfoldHeading(_ sender: Any?) {
        commitComposition()
        if let heading = headingAtCursor(), heading.folded { onToggleFold?(heading.key) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let control = foldControls.first(where: { $0.triangle.contains(point) || ($0.pill?.insetBy(dx: -2, dy: -2).contains(point) ?? false) }) {
            commitComposition()
            onToggleFold?(control.key)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for control in foldControls {
            addCursorRect(control.triangle, cursor: .pointingHand)
            if let pill = control.pill { addCursorRect(pill, cursor: .pointingHand) }
        }
    }
}
