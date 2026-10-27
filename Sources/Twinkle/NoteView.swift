import AppKit
import SwiftUI

/// 스티커 창 하나의 모양 상태 (색, 바탕화면/항상 위)
@MainActor
final class NoteAppearance: ObservableObject {
    @Published var color: NoteColor
    @Published var level: NoteLevel

    init(color: NoteColor, level: NoteLevel) {
        self.color = color
        self.level = level
    }
}

struct NoteView: View {
    @ObservedObject var document: NoteDocument
    @ObservedObject var appearance: NoteAppearance
    @ObservedObject var runner: AgentRunner
    let workspaces: WorkspaceStore
    var onOpenLink: (String) -> Void
    var onTextViewReady: (NSTextView) -> Void
    var onOpenThread: (Int, NSRect) -> Void
    var onInsertText: (String) -> Void
    var onOpenTodo: (Todo) -> Void
    var onNew: () -> Void
    var onToggleLevel: () -> Void
    var onClose: () -> Void
    /// 상단 바 우클릭 메뉴
    var headerMenu: () -> NSMenu?

    @State private var showsWorkspaces = false

    var body: some View {
        VStack(spacing: 0) {
            header
            MarkdownEditor(document: document, onOpenLink: onOpenLink, onTextViewReady: onTextViewReady, onOpenThread: onOpenThread, onOpenTodo: onOpenTodo)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
        }
        .background(Color(nsColor: appearance.color.nsColor))
        .ignoresSafeArea()
    }

    /// 이 메모의 todo를 맡아 일하는 중인 에이전트들
    private var workingAgents: [AgentKind] {
        AgentKind.allCases.filter { runner.jobs[$0]?.todo.docPath == document.relativePath }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                // 항상 위에 고정된 메모: 제목 앞에 핀 (누르면 고정 풀기)
                if appearance.level == .floating {
                    Button(action: onToggleLevel) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(30))
                    }
                    .help("고정 풀기 (바탕화면에 붙이기)")
                }
                Text(document.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }

            ForEach(workingAgents) { kind in
                AgentBadge(kind: kind, size: 14)
                    .help("\(kind.displayName) 작업 중")
            }

            Spacer(minLength: 4)

            Button(action: onNew) { Image(systemName: "plus") }
                .help("새 메모")

            Button { showsWorkspaces.toggle() } label: { Image(systemName: "folder") }
                .help("작업 폴더")
                .popover(isPresented: $showsWorkspaces, arrowEdge: .bottom) {
                    WorkspaceBrowser(store: workspaces, onInsert: onInsertText)
                }


            // 색·고정·Finder·삭제 (상단 바 우클릭과 같은 메뉴)
            MoreButton(menu: headerMenu)
                .frame(width: 16, height: 16)
                .help("더 보기")

            Button(action: onClose) { Image(systemName: "xmark") }
                .help("닫기 (파일은 그대로 남음)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.black.opacity(0.55))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(DragHandle(menu: headerMenu))
        .background(.black.opacity(0.04))
    }
}

/// 메모 헤더, 할 일 창에 쓰는 작은 에이전트 로고
struct AgentBadge: View {
    let kind: AgentKind
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = AgentLogos.image(for: kind) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
                    .background(Circle().fill(.white))
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(nsColor: kind.color)))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 0.5))
    }
}

/// 헤더의 빈 영역을 잡고 창을 끌어 옮길 수 있게 해 줌
private struct DragHandle: NSViewRepresentable {
    var menu: () -> NSMenu?

    final class HandleView: NSView {
        var menuProvider: (() -> NSMenu?)?

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // 상단 바 우클릭 → 메모 메뉴 (끌기 영역이라 SwiftUI 우클릭 메뉴 대신 여기서)
        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = HandleView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandleView)?.menuProvider = menu
    }
}

/// 헤더의 … 버튼. 누르면 버튼 바로 아래에 메모 메뉴를 띄움 (SwiftUI Menu는 맨 위 색 동그라미 줄을 못 그려서 NSMenu로)
private struct MoreButton: NSViewRepresentable {
    var menu: () -> NSMenu?

    final class ButtonView: NSImageView {
        var menuProvider: (() -> NSMenu?)?

        override func mouseDown(with event: NSEvent) {
            guard let menu = menuProvider?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: -6, y: -6), in: self)
        }
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = ButtonView()
        view.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "더 보기")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        view.contentTintColor = NSColor.black.withAlphaComponent(0.55)
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        (nsView as? ButtonView)?.menuProvider = menu
    }
}

/// 메뉴 맨 위의 색 고르기 줄: 색 동그라미를 가로로, 지금 색은 테두리로
final class ColorSwatchMenuView: NSView {
    private let selected: NoteColor
    private let onPick: (NoteColor) -> Void
    private var hovered: NoteColor?

    private static let diameter: CGFloat = 18
    private static let spacing: CGFloat = 10
    private static let inset: CGFloat = 14

    init(selected: NoteColor, onPick: @escaping (NoteColor) -> Void) {
        self.selected = selected
        self.onPick = onPick
        let count = CGFloat(NoteColor.allCases.count)
        let width = Self.inset * 2 + count * Self.diameter + (count - 1) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        autoresizingMask = [.width]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rect(for index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.diameter + Self.spacing),
               y: (bounds.height - Self.diameter) / 2,
               width: Self.diameter, height: Self.diameter)
    }

    private func color(at point: NSPoint) -> NoteColor? {
        NoteColor.allCases.indices.first { rect(for: $0).insetBy(dx: -Self.spacing / 2, dy: -6).contains(point) }
            .map { NoteColor.allCases[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in NoteColor.allCases.enumerated() {
            let circle = rect(for: index)
            let grow: CGFloat = color == hovered ? 1.5 : 0
            let path = NSBezierPath(ovalIn: circle.insetBy(dx: -grow, dy: -grow))
            color.nsColor.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if color == selected {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3.5, dy: -3.5))
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let next = color(at: convert(event.locationInWindow, from: nil))
        guard next != hovered else { return }
        hovered = next
        toolTip = next?.label
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let color = color(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick(color)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

/// 클로저로 동작하는 메뉴 항목
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
