import AppKit
import Combine
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
    /// ``` 코드 블록 (배경을 블록 단위로 그림)
    static let twinkleCodeBlock = NSAttributedString.Key("twinkleCodeBlock")
    /// 버튼처럼 그릴 칩: "path:<경로>" 또는 "date"
    static let twinkleChip = NSAttributedString.Key("twinkleChip")
}

/// NSTextView 기반 마크다운 편집기. 원문은 그대로 두고 글자 모양만 입혀서 보여줌
struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var document: NoteDocument
    var onOpenLink: (String) -> Void
    var onTextViewReady: (NSTextView) -> Void = { _ in }
    /// 댓글 줄 클릭: todo 줄 번호, 클릭한 글자의 화면 위치
    var onOpenThread: (Int, NSRect) -> Void = { _, _ in }
    /// 쿼리 목록·달력에서 할 일의 메모 이름을 누름 → 그 할 일 위치로
    var onOpenTodo: (Todo) -> Void = { _ in }

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
        context.coordinator.appliedFolds = document.foldedHeadings
        context.coordinator.textView = textView
        context.coordinator.attach(to: textView)
        context.coordinator.restyle()
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
        /// `@`를 치면 뜨는 에이전트 목록
        let suggestions = AgentSuggestionPopup()
        /// 마지막으로 그린 접힘 상태
        var appliedFolds: Set<String> = []
        /// `- [` 자동완성 직후 사용자가 습관대로 치는 " ] "를 삼키기 위한 기대 문자들
        private var swallow: (location: Int, characters: [String])?

        private static let todoLine = /^(\s*)([-*+]) \[.\] ?(.*)$/
        private static let bulletLine = /^(\s*)([-*+]) (?!↳)(.*)$/

        init(parent: MarkdownEditor) {
            self.parent = parent
            super.init()
            suggestions.onAccept = { [weak self] kind, range in
                guard let textView = self?.textView else { return }
                (textView as? MarkdownTextView)?.commitComposition()
                textView.insertText("@\(kind.rawValue) ", replacementRange: range)
            }
        }

        // MARK: 다시 그리기, ```tasks 블록

        private var taskBlocks: [TaskBlock] = []
        private var taskViews: [(model: TaskBlockModel, view: NSView)] = []
        private var cancellables: Set<AnyCancellable> = []

        /// 다른 메모의 할 일이 바뀌어도 쿼리 결과를 갱신하고, 창 크기가 바뀌면 목록 위치를 다시 잡음
        func attach(to textView: NSTextView) {
            parent.document.library?.$todos
                .dropFirst()
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, !self.taskBlocks.isEmpty else { return }
                    self.restyle()
                }
                .store(in: &cancellables)
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: textView)
                .sink { [weak self] _ in self?.positionTaskViews() }
                .store(in: &cancellables)
        }

        private var lastLineCount = -1
        /// 한글 조합 중이라 건너뛴 다시 칠하기가 있음 (조합이 끝나면 함)
        private var skippedForComposition = false
        private var queryCache = TaskBlock.Cache()

        /// 글자 모양을 다시 입힘. 한글 조합 중이면 입력기가 깨지니 건너뜀.
        /// edited가 있고 한 줄 안의 단순한 수정이면 그 줄만 칠함 (타이핑할 때 대부분)
        func restyle(storage: NSTextStorage? = nil, edited: NSRange? = nil, delta: Int = 0) {
            guard let textView, let storage = storage ?? textView.textStorage else { return }
            guard !textView.hasMarkedText() else {
                skippedForComposition = true
                return
            }
            skippedForComposition = false
            let string = storage.string as NSString
            var lineCount = 1
            for index in 0..<string.length where string.character(at: index) == 10 { lineCount += 1 }
            defer { lastLineCount = lineCount }

            if let edited, lineCount == lastLineCount, isSimpleEdit(edited, in: string) {
                var line = string.lineRange(for: NSRange(location: min(edited.location, string.length), length: 0))
                if NSMaxRange(line) > line.location, NSMaxRange(line) <= string.length, string.character(at: NSMaxRange(line) - 1) == 10 {
                    line.length -= 1
                }
                MarkdownStyler.apply(
                    to: storage,
                    folded: parent.document.foldedHeadings,
                    revealLine: parent.document.editingLine,
                    only: line
                )
                // 뒤에 있는 쿼리 블록은 글자 수만큼 밀리고, 줄이 길어져 아래로 밀렸을 수도 있으니 목록 위치를 다시 잡음
                if !taskBlocks.isEmpty {
                    taskBlocks = taskBlocks.map { $0.startOffset >= edited.location ? $0.shifted(by: delta) : $0 }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.positionTaskViews() }
                    }
                }
                return
            }

            // 제목·구조를 건드린 수정이면 쿼리 결과(제목별 묶기 등)도 새로 계산
            if edited != nil { queryCache = TaskBlock.Cache() }
            taskBlocks = TaskBlock.find(in: storage.string, revealLine: parent.document.editingLine, library: parent.document.library, cache: &queryCache)
            MarkdownStyler.apply(
                to: storage,
                folded: parent.document.foldedHeadings,
                revealLine: parent.document.editingLine,
                taskBlocks: taskBlocks
            )
            // 레이아웃이 끝난 뒤에 목록 위치를 잡음
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.positionTaskViews() }
            }
        }

        /// 커서가 다른 줄로 옮겨감: 링크·경로 원문을 드러내거나 숨기면 되니 두 줄만 다시 칠함.
        /// 쿼리 블록에 드나들 때만 전체 (블록을 펼치거나 접어야 해서)
        private func revealChanged(from old: Int?, to new: Int?) {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return restyle() }
            let string = storage.string as NSString
            let lines = [old, new].compactMap { $0 }
            var ranges: [NSRange] = []
            var lineStart = 0, lineIndex = 0
            // 해당 줄들의 범위 (줄바꿈 제외)
            while lineIndex <= (lines.max() ?? -1), lineStart <= string.length {
                let range = string.lineRange(for: NSRange(location: lineStart, length: 0))
                if lines.contains(lineIndex) {
                    var content = range
                    if NSMaxRange(content) > content.location, string.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
                    ranges.append(content)
                }
                if NSMaxRange(range) == lineStart { break }
                lineStart = NSMaxRange(range)
                lineIndex += 1
            }
            let touchesBlock = ranges.contains { MarkdownStyler.isInsideFence(at: $0.location, in: string) }
            let structural = ranges.contains { range in
                let text = string.substring(with: range).trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("#") || text.contains("```") || text.contains("- ↳ ")
            }
            guard !touchesBlock, !structural, ranges.count == lines.count else { return restyle() }
            for range in ranges {
                MarkdownStyler.apply(to: storage, folded: parent.document.foldedHeadings, revealLine: new, only: range)
            }
        }

        /// 한 줄만 다시 칠해도 되는 수정인지: 제목·댓글·코드 펜스 줄이나 쿼리 블록 안이 아니어야 함
        private func isSimpleEdit(_ edited: NSRange, in string: NSString) -> Bool {
            guard edited.location <= string.length else { return false }
            let line = string.substring(with: string.lineRange(for: NSRange(location: edited.location, length: 0)))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || line.contains("```") || line.contains("- ↳ ") { return false }
            // 코드·쿼리 블록 안이면 블록 전체를 다시 그려야 함
            return !MarkdownStyler.isInsideFence(at: edited.location, in: string)
        }

        /// 접힌 ```tasks 블록 자리에 할 일 목록을 띄움
        private func positionTaskViews() {
            guard !taskBlocks.isEmpty || !taskViews.isEmpty else { return }
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let library = parent.document.library
            else { return }
            let shown = taskBlocks.filter { !$0.revealed }
            while taskViews.count < shown.count {
                let model = TaskBlockModel()
                let index = taskViews.count
                let view = NSHostingView(rootView: TaskQueryView(
                    model: model,
                    library: library,
                    notePath: parent.document.relativePath,
                    onOpenTodo: { [weak self] in self?.parent.onOpenTodo($0) },
                    onEdit: { [weak self] in self?.editTaskBlock(index) },
                    onChangeQuery: { [weak self] in self?.replaceQuery(of: index, with: $0) }
                ))
                view.sizingOptions = []
                textView.addSubview(view)
                taskViews.append((model, view))
            }
            while taskViews.count > shown.count {
                taskViews.removeLast().view.removeFromSuperview()
            }
            layoutManager.ensureLayout(for: container)
            let string = textView.string as NSString
            for (index, block) in shown.enumerated() {
                let (model, view) = taskViews[index]
                if model.groups.map(\.id) != block.groups.map(\.id) || model.groups.flatMap(\.items).map(\.todo) != block.groups.flatMap(\.items).map(\.todo) {
                    model.groups = block.groups
                }
                if model.errors != block.errors { model.errors = block.errors }
                if model.queryLines != block.queryLines { model.queryLines = block.queryLines }
                guard block.startOffset < string.length else { continue }
                let glyph = layoutManager.glyphIndexForCharacter(at: block.startOffset)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let origin = textView.textContainerOrigin
                view.frame = NSRect(
                    x: origin.x + MarkdownTextView.gutterWidth,
                    y: origin.y + line.minY + 4,
                    width: max(container.size.width - MarkdownTextView.gutterWidth - 10, 100),
                    height: block.height
                )
            }
        }

        // MARK: 날짜 칩 → 달력

        private var datePopover: BubblePanel?

        private func openDatePicker(range: NSRange, in textView: NSTextView) {
            let string = textView.string as NSString
            guard NSMaxRange(range) <= string.length, let date = MarkdownStyler.chipDate(string.substring(with: range)),
                  let library = parent.document.library
            else { return }
            // 날짜 칩의 화면 위치 (첫 줄)
            let anchor = textView.firstRect(forCharacterRange: range, actualRange: nil)

            datePopover?.close()
            let popover = BubblePanel(content: DateChipView(
                original: date,
                library: library,
                onChoose: { [weak self, weak textView] newDate in
                    self?.datePopover?.close()
                    guard let textView else { return }
                    // 그 사이 글자가 바뀌었으면 바꾸지 않음
                    let current = textView.string as NSString
                    guard NSMaxRange(range) <= current.length, MarkdownStyler.chipDate(current.substring(with: range)) == date else { return }
                    textView.insertText(MarkdownStyler.chipText(newDate), replacementRange: range)
                },
                onOpenTodo: { [weak self] in
                    self?.datePopover?.close()
                    self?.parent.onOpenTodo($0)
                }
            ), anchor: anchor, gap: 4, preferAbove: false, onClose: { [weak self] in self?.datePopover = nil })
            datePopover = popover
            popover.present()
        }

        /// 조건 버튼: 블록 안 쿼리 줄을 새로 씀 (실행 취소 가능하게 텍스트 뷰로 입력)
        private func replaceQuery(of index: Int, with lines: [String]) {
            let shown = taskBlocks.filter { !$0.revealed }
            guard let textView, shown.indices.contains(index) else { return }
            let text = lines.map { $0 + "\n" }.joined()
            let range = shown[index].queryRange
            guard NSMaxRange(range) <= (textView.string as NSString).length,
                  textView.shouldChangeText(in: range, replacementString: text)
            else { return }
            textView.textStorage?.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }

        /// "쿼리 편집": 블록 안으로 커서를 옮겨 원문을 드러냄
        private func editTaskBlock(_ index: Int) {
            let shown = taskBlocks.filter { !$0.revealed }
            guard let textView, shown.indices.contains(index) else { return }
            textView.window?.makeKeyAndOrderFront(nil)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: shown[index].queryOffset, length: 0))
        }

        /// 제목을 접거나 펼친 뒤 다시 그림. 커서가 숨은 곳에 있으면 제목 끝으로 옮김
        func applyFolds(in textView: NSTextView) {
            (textView as? MarkdownTextView)?.commitComposition()
            guard let storage = textView.textStorage else { return }
            appliedFolds = parent.document.foldedHeadings
            restyle()
            let location = textView.selectedRange().location
            var hiddenRange = NSRange()
            if location < storage.length,
               storage.attribute(.twinkleHidden, at: location, longestEffectiveRange: &hiddenRange, in: NSRange(location: 0, length: storage.length)) != nil {
                textView.setSelectedRange(NSRange(location: hiddenRange.location, length: 0))
            }
            textView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            let before = parent.document.editingLine
            updateEditingLine()
            if parent.document.editingLine != before { revealChanged(from: before, to: parent.document.editingLine) }
            if let textView { suggestions.update(in: textView) }
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.document.editingLine = nil
            restyle()
            suggestions.hide()
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
            if skippedForComposition, !textView.hasMarkedText() { restyle() }
            parent.document.text = textView.string
            suggestions.update(in: textView)
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
                restyle(storage: textStorage, edited: editedRange, delta: delta)
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

        /// 엔터: todo/목록 줄이면 다음 줄에 같은 머리를 이어 줌. 빈 항목에서 엔터면 목록 끝내기
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // 에이전트 목록이 떠 있으면 ↑↓ 고르기, ⏎/Tab 넣기, Esc 닫기
            if suggestions.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): suggestions.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): suggestions.move(1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): suggestions.accept(); return true
                case #selector(NSResponder.cancelOperation(_:)): suggestions.dismiss(); return true
                default: break
                }
            }
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
            case "path":
                let path = "/" + value
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            case "date":
                let parts = value.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2 else { return true }
                openDatePicker(range: NSRange(location: parts[0], length: parts[1]), in: textView)
            case "thread":
                // 줄 전체 대신 클릭한 글자 한 칸 (접힌 이전 댓글이 그 줄 앞에 붙어 있어 줄 사각형은 엉뚱함)
                guard let line = Int(value) else { return true }
                parent.onOpenThread(line, textView.firstRect(forCharacterRange: NSRange(location: charIndex, length: 1), actualRange: nil))
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
    private static let markdownLink = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]\\n]+)\\]\\((\\S+?)\\)")
    private static let bareURL = try! NSRegularExpression(pattern: "https?://[^\\s<>`)\\]]+")
    private static let agentTag = try! NSRegularExpression(pattern: "@(claude|codex|grok)\\b", options: .caseInsensitive)
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    /// revealLine: 커서가 있는 줄. 이 줄의 마크다운 링크는 원문 그대로 보여서 고칠 수 있음
    /// only: 이 범위(한 줄)만 다시 칠함. 줄 단위 꾸미기만 하고 여러 줄 구조(접기, 쿼리 블록)는 그대로 둠
    static func apply(to storage: NSTextStorage, folded: Set<String> = [], revealLine: Int? = nil, taskBlocks: [TaskBlock] = [], only: NSRange? = nil) {
        let string = storage.string as NSString
        let full = NSRange(location: 0, length: string.length)
        let scope = only.map { NSIntersectionRange($0, full) } ?? full
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.firstLineHeadIndent = MarkdownTextView.gutterWidth
        paragraph.headIndent = MarkdownTextView.gutterWidth

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraph], range: scope)

        heading.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
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

        checkbox.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
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


        bold.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: match.range)
        }

        code.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match else { return }
            // 백틱 안이 실제 있는 경로면, 커서가 없는 줄에선 [📁 이름] 칩으로
            let inner = NSRange(location: match.range.location + 1, length: match.range.length - 2)
            let content = string.substring(with: inner)
            if lineNumber(at: match.range.location) != revealLine, let path = existingPath(content) {
                styleChipPath(storage, match: match.range, inner: inner, content: content, path: path)
                return
            }
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .backgroundColor: NSColor.black.withAlphaComponent(0.06),
            ], range: match.range)
        }

        // yyyy.mm.dd 날짜는 칩으로. 누르면 달력
        datePattern.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match, chipDate(string.substring(with: match.range)) != nil else { return }
            storage.addAttributes([
                .twinkleChip: "date",
                .link: URL(string: "twinkle://date/\(match.range.location)-\(match.range.length)")!,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: dateColor,
            ], range: match.range)
            // 칩 안쪽 여백, 앞 글자와도 조금 띄움
            storage.addAttribute(.kern, value: 3, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            if match.range.location > 0, string.character(at: match.range.location - 1) != 10 {
                storage.addAttribute(.kern, value: 4, range: NSRange(location: match.range.location - 1, length: 1))
            }
        }

        wikiLink.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match else { return }
            let target = string.substring(with: match.range(at: 1))
            guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "twinkle://open/\(encoded)")
            else { return }
            storage.addAttributes([.link: url, .foregroundColor: linkColor], range: match.range)
        }

        // [글자](주소): 커서가 없는 줄에선 글자만 링크로 보이고 괄호와 주소는 숨김
        var linkRanges: [NSRange] = []
        markdownLink.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match else { return }
            linkRanges.append(match.range)
            let textRange = match.range(at: 1)
            let address = string.substring(with: match.range(at: 2))
            let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
            if let url {
                storage.addAttributes([
                    .link: url,
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: linkColor.withAlphaComponent(0.35),
                ], range: textRange)
            }
            if lineNumber(at: match.range.location) == revealLine {
                storage.addAttribute(.foregroundColor, value: mutedColor, range: NSRange(location: NSMaxRange(textRange), length: NSMaxRange(match.range) - NSMaxRange(textRange)))
            } else {
                storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: match.range.location, length: 1))
                storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: NSMaxRange(textRange), length: NSMaxRange(match.range) - NSMaxRange(textRange)))
            }
        }

        // 그냥 붙여 넣은 주소도 누르면 열리게
        bareURL.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match, !linkRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let url = URL(string: string.substring(with: match.range))
            else { return }
            storage.addAttributes([.link: url, .foregroundColor: linkColor], range: match.range)
        }

        agentTag.enumerateMatches(in: storage.string, range: scope) { match, _, _ in
            guard let match,
                  let kind = AgentKind(rawValue: string.substring(with: match.range(at: 1)).lowercased())
            else { return }
            storage.addAttributes([
                .foregroundColor: kind.color,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            ], range: match.range)
        }

        if only == nil {
            let fenced = styleCodeBlocks(in: storage, lineStarts: lineStarts, revealLine: revealLine)
            foldComments(in: storage, lineStarts: lineStarts)
            foldHeadings(in: storage, lineStarts: lineStarts, folded: folded, skipping: fenced)
            layoutTaskBlocks(in: storage, blocks: taskBlocks, base: paragraph)
        }
        // 숨긴 글자의 간격·배경색·밑줄·취소선은 없앰. 글자는 폭 0으로 접혀도 이것들은 접힌 자리
        // (앞 글자 위)에 그려져서, 숨은 `코드` 배경이 겹겹이 쌓여 앞 글자가 하이라이트처럼 보였음
        storage.enumerateAttribute(.twinkleHidden, in: scope) { value, range, _ in
            guard value != nil else { return }
            for key: NSAttributedString.Key in [.kern, .backgroundColor, .underlineStyle, .strikethroughStyle] {
                storage.removeAttribute(key, range: range)
            }
        }
        // 시스템 폰트에 없는 글자(한글, ↳ 등)에 대체 폰트를 다시 지정. 안 하면 TextKit 1에서 글자가 사라짐
        storage.fixAttributes(in: scope)

        storage.endEditing()
        // 숨김 속성이 바뀌었으니 글리프를 다시 만들게 함
        for layoutManager in storage.layoutManagers {
            layoutManager.invalidateGlyphs(forCharacterRange: scope, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: scope, actualCharacterRange: nil)
        }
    }

    // MARK: 칩 (경로, 날짜)

    nonisolated static let dateColor = NSColor(red: 0.12, green: 0.40, blue: 0.75, alpha: 1)
    private static let datePattern = try! NSRegularExpression(pattern: "(?<![\\d.])\\d{4}\\.\\d{1,2}\\.\\d{1,2}(?![\\d.])")

    /// "2026.10.28" → 날짜 (없는 날짜면 nil)
    static func chipDate(_ text: String) -> Date? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        components.calendar = Calendar.current
        guard components.isValidDate, let date = components.date else { return nil }
        return date
    }

    static func chipText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }

    /// `~/…`나 `/…`이고 실제로 있으면 펼친 경로
    private static func existingPath(_ content: String) -> String? {
        guard content.hasPrefix("~/") || content.hasPrefix("/") else { return nil }
        let path = (content as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// `경로` → 여는 백틱 자리에 아이콘, 앞쪽 경로는 숨기고 마지막 이름만
    private static func styleChipPath(_ storage: NSTextStorage, match: NSRange, inner: NSRange, content: String, path: String) {
        let trimmed = content.hasSuffix("/") ? String(content.dropLast()) : content
        let nameStart = trimmed.range(of: "/", options: .backwards).map { trimmed[..<$0.upperBound].utf16.count } ?? 0
        let nameLength = trimmed.utf16.count - nameStart
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "twinkle://path\(encoded.hasPrefix("/") ? "" : "/")\(encoded)")
        else { return }

        storage.addAttributes([
            .twinkleChip: "path:\(path)",
            .link: url,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: textColor,
        ], range: match)
        // 여는 백틱: 안 보이게 하고 아이콘 자리만큼 띄움
        storage.addAttributes([.foregroundColor: NSColor.clear, .kern: 15], range: NSRange(location: match.location, length: 1))
        if nameStart > 0 {
            storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: inner.location, length: nameStart))
        }
        // 끝 슬래시와 닫는 백틱은 안 보이게 (닫는 백틱은 오른쪽 여백)
        let tailStart = inner.location + nameStart + nameLength
        if NSMaxRange(inner) > tailStart {
            storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: tailStart, length: NSMaxRange(inner) - tailStart))
        }
        storage.addAttributes([.foregroundColor: NSColor.clear, .kern: -2], range: NSRange(location: NSMaxRange(match) - 1, length: 1))
    }

    // MARK: 코드 블록

    /// location이 있는 줄이 ``` 펜스 줄이거나 펜스 안인지 (문서 처음부터 펜스를 셈)
    static func isInsideFence(at location: Int, in string: NSString) -> Bool {
        var inside = false
        var start = 0
        while start <= string.length {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            let isFence = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
            if location < NSMaxRange(line) || NSMaxRange(line) >= string.length {
                return inside || isFence
            }
            if isFence { inside.toggle() }
            if NSMaxRange(line) == start { break }
            start = NSMaxRange(line)
        }
        return inside
    }

    static let taskFences: Set<String> = ["```tasks", "```todo", "```todos"]

    /// ```언어 … ``` (할 일 쿼리 블록 제외): 안쪽은 고정폭, 펜스 줄은 작고 흐리게, 블록 배경은 레이아웃 매니저가 그림.
    /// 펜스 안 줄 번호들을 돌려줌 (코드 안의 # 주석을 제목으로 접지 않게)
    @discardableResult
    private static func styleCodeBlocks(in storage: NSTextStorage, lineStarts: [Int], revealLine: Int?) -> Set<Int> {
        let string = storage.string as NSString
        let lines = storage.string.split(separator: "\n", omittingEmptySubsequences: false)
        var fenced: Set<Int> = []
        var index = 0
        while index < lines.count {
            let opening = lines[index].trimmingCharacters(in: .whitespaces)
            guard opening.hasPrefix("```"),
                  let end = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" })
            else {
                index += 1
                continue
            }
            fenced.formUnion(index...end)
            if !taskFences.contains(opening.lowercased()), lineStarts.indices.contains(end) {
                let start = lineStarts[index]
                let stop = lineStarts[end] + lines[end].utf16.count
                let block = NSRange(location: start, length: stop - start)
                let code = NSMutableParagraphStyle()
                code.firstLineHeadIndent = MarkdownTextView.gutterWidth + 8
                code.headIndent = MarkdownTextView.gutterWidth + 8
                code.lineSpacing = 2
                storage.setAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: textColor,
                    .paragraphStyle: code,
                    .twinkleCodeBlock: true,
                ], range: block)
                let revealed = revealLine.map { (index...end).contains($0) } ?? false
                for fence in [index, end] {
                    let fenceRange = NSRange(location: lineStarts[fence], length: lines[fence].utf16.count)
                    if revealed {
                        // 커서가 블록 안: 펜스를 작고 흐리게 보여서 고칠 수 있게
                        storage.addAttributes([
                            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                            .foregroundColor: mutedColor,
                        ], range: fenceRange)
                    } else {
                        // 렌더링 상태: 펜스 줄은 투명한 1pt 글자로 높이만 없앰 (위아래 여백 4pt)
                        let tiny = code.mutableCopy() as! NSMutableParagraphStyle
                        tiny.minimumLineHeight = 1
                        tiny.maximumLineHeight = 1
                        tiny.lineSpacing = 0
                        tiny.paragraphSpacing = fence == index ? 4 : 0
                        tiny.paragraphSpacingBefore = fence == end ? 4 : 0
                        storage.addAttributes([
                            .font: NSFont.systemFont(ofSize: 1),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: tiny,
                        ], range: NSRange(location: fenceRange.location, length: max(fenceRange.length, 0)))
                        // 줄바꿈 글자도 같은 문단 모양이어야 높이가 줄어듦
                        if NSMaxRange(fenceRange) < string.length {
                            storage.addAttribute(.paragraphStyle, value: tiny, range: NSRange(location: NSMaxRange(fenceRange), length: 1))
                        }
                    }
                }
                _ = string
            }
            index = end + 1
        }
        return fenced
    }

    // MARK: ```tasks 블록

    /// 커서가 블록 안이면 원문을 코드처럼, 아니면 원문을 투명한 1pt 글자로 만들고 목록 높이만큼 자리를 비움.
    /// (글리프 숨기기를 쓰면 줄바꿈 뒤 숨긴 글자가 앞 줄에 붙어 블록이 자기 자리를 못 가짐 — TextKit 1)
    private static func layoutTaskBlocks(in storage: NSTextStorage, blocks: [TaskBlock], base: NSParagraphStyle) {
        let string = storage.string as NSString
        for block in blocks {
            let range = NSRange(location: block.startOffset, length: block.endOffset - block.startOffset)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            if block.revealed {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: textColor,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.05),
                ], range: range)
                continue
            }
            let tiny = base.mutableCopy() as! NSMutableParagraphStyle
            tiny.minimumLineHeight = 1
            tiny.maximumLineHeight = 1
            tiny.lineSpacing = 0
            tiny.paragraphSpacingBefore = 0
            tiny.paragraphSpacing = 0
            storage.setAttributes([
                .paragraphStyle: tiny,
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
            ], range: range)
            // 닫는 줄 아래에 목록이 들어갈 공간
            let lastLine = string.lineRange(for: NSRange(location: max(NSMaxRange(range) - 1, range.location), length: 0))
            let reserved = tiny.mutableCopy() as! NSMutableParagraphStyle
            reserved.paragraphSpacing = block.height + 8
            storage.addAttribute(.paragraphStyle, value: reserved, range: NSIntersectionRange(lastLine, NSRange(location: 0, length: storage.length)))
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
    private static func foldHeadings(in storage: NSTextStorage, lineStarts: [Int], folded: Set<String>, skipping fenced: Set<Int> = []) {
        let string = storage.string
        let length = (string as NSString).length
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let headings: [(line: Int, level: Int, key: String)] = lines.enumerated().compactMap { index, line in
            guard !fenced.contains(index), let match = line.wholeMatch(of: headingLine) else { return nil }
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

            // 예전 한 줄 댓글은 결론이 보통 끝에 있으니 마지막 문장을 보여줌 (앞은 숨기고 "…")
            var head = 0
            if !shown.contains("<br>"), shown.count > collapsedLength,
               let last = shown.ranges(of: /[.!?다요]\.?\s+/).last, shown[last.upperBound...].count >= 6 {
                head = shown[..<last.upperBound].utf16.count
                storage.addAttribute(.twinkleEllipsis, value: true, range: NSRange(location: contentStart, length: 1))
                if head > 1 {
                    storage.addAttribute(.twinkleHidden, value: true, range: NSRange(location: contentStart + 1, length: head - 1))
                }
                shown = String(shown[last.upperBound...])
            }
            // 숨은 정보 + 긴 내용은 잘라서 "…"
            let shownLength = head + shown.utf16.count
            var cut = shownLength
            if shown.count > collapsedLength {
                cut = head + String(shown.prefix(collapsedLength)).utf16.count
            }
            // 여러 줄 댓글(<br>)은 첫 줄까지만
            if let br = shown.range(of: "<br>") {
                cut = min(cut, shown[..<br.lowerBound].utf16.count)
                if cut == 0 { cut = min(shownLength, String(shown.prefix(collapsedLength)).utf16.count) }
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

    private var iconCache: [String: NSImage] = [:]

    /// 칩 배경(둥근 사각형)과 경로 칩의 아이콘을 글자 뒤에 그림
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // 코드 블록: 첫 줄부터 끝 줄까지 하나의 둥근 배경
        storage.enumerateAttribute(.twinkleCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, NSIntersectionRange(range, characters).length > 0 || range.location == characters.location else { return }
            let first = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: max(NSMaxRange(range) - 1, range.location)), effectiveRange: nil)
            let rect = NSRect(
                x: origin.x + MarkdownTextView.gutterWidth - 2,
                y: origin.y + first.minY,
                width: container.size.width - MarkdownTextView.gutterWidth - 6,
                height: last.maxY - first.minY
            )
            NSColor.black.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        storage.enumerateAttribute(.twinkleChip, in: characters) { value, range, _ in
            guard let kind = value as? String else { return }
            // 접힌 댓글 안의 칩처럼 글자가 전부 숨겨졌으면 그리지 않음
            var visible = false
            storage.enumerateAttribute(.twinkleHidden, in: range) { hidden, _, stop in
                if hidden == nil {
                    visible = true
                    stop.pointee = true
                }
            }
            guard visible else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let isDate = kind == "date"
            var first: NSRect?
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                var chip = rect.offsetBy(dx: origin.x, dy: origin.y)
                chip = NSRect(x: chip.minX - (isDate ? 4 : 0), y: chip.midY - 10, width: chip.width + (isDate ? 5 : 2), height: 20)
                if first == nil { first = chip }
                let path = NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6)
                (isDate ? MarkdownStyler.dateColor.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).setFill()
                path.fill()
                (isDate ? MarkdownStyler.dateColor.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.12)).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            if kind.hasPrefix("path:"), let chip = first {
                let path = String(kind.dropFirst(5))
                let icon = iconCache[path] ?? NSWorkspace.shared.icon(forFile: path)
                iconCache[path] = icon
                icon.draw(in: NSRect(x: chip.minX + 4, y: chip.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
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
    /// 마지막 글자가 조합 중 하이라이트로 남지 않음.
    /// 입력기에 먼저 확정하라고 알리고, 그래도 남아 있으면 조합 중인 글자를 같은 글자로 입력 확정
    func commitComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        guard hasMarkedText() else { return }
        let range = markedRange()
        let composing = (string as NSString).substring(with: range)
        insertText(composing, replacementRange: range)
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

/// 메모 안 ```tasks … ``` 블록 하나
struct TaskBlock {
    /// 여는 줄 첫 글자 ~ 닫는 줄 끝(줄바꿈 제외)
    var startOffset: Int
    var endOffset: Int
    /// 쿼리 첫 줄의 시작 (편집할 때 커서 둘 곳)
    var queryOffset: Int
    /// 여는 줄과 닫는 줄 사이 (버튼으로 조건을 바꾸면 이 범위를 다시 씀)
    var queryRange: NSRange

    /// 앞쪽에서 글자가 늘거나 줄면 위치만 옮김 (한 줄만 다시 칠할 때)
    func shifted(by delta: Int) -> TaskBlock {
        var block = self
        block.startOffset += delta
        block.endOffset += delta
        block.queryOffset += delta
        block.queryRange.location += delta
        return block
    }
    let queryLines: [String]
    let revealed: Bool
    let groups: [TaskGroup]
    let errors: [String]
    let height: CGFloat

    /// 쿼리 문장 + 할 일 목록 버전이 같으면 결과를 다시 계산하지 않음
    struct Cache {
        var entries: [String: (groups: [TaskGroup], errors: [String])] = [:]
        var version = -1
    }

    @MainActor
    static func find(in text: String, revealLine: Int?, library: NoteLibrary?, cache: inout Cache) -> [TaskBlock] {
        guard text.contains("```"), let library else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var offsets: [Int] = []
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf16.count + 1
        }

        var blocks: [TaskBlock] = []
        var index = 0
        while index < lines.count {
            guard ["```tasks", "```todo", "```todos"].contains(lines[index].trimmingCharacters(in: .whitespaces).lowercased()) else {
                index += 1
                continue
            }
            guard let end = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) else { break }
            let queryLines = lines[(index + 1)..<end].map(String.init)
            let source = queryLines.joined(separator: "\n")
            // 조건 없이 ```todo ``` 만 쓰면 안 끝난 할 일
            if cache.version != library.todosVersion {
                cache = Cache(version: library.todosVersion)
            }
            let (groups, errors): ([TaskGroup], [String])
            if let hit = cache.entries[source] {
                (groups, errors) = hit
            } else {
                let query = TaskQuery.parse(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "not done" : source)
                (groups, errors) = (query.run(in: library), query.errors)
                cache.entries[source] = (groups, errors)
            }
            blocks.append(TaskBlock(
                startOffset: offsets[index],
                endOffset: offsets[end] + lines[end].utf16.count,
                queryOffset: offsets[min(index + 1, end)],
                queryRange: NSRange(location: offsets[index + 1], length: offsets[end] - offsets[index + 1]),
                queryLines: queryLines,
                revealed: revealLine.map { (index...end).contains($0) } ?? false,
                groups: groups,
                errors: errors,
                height: TaskQueryView.height(groups: groups, errors: errors)
            ))
            index = end + 1
        }
        return blocks
    }
}
