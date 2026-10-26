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
            Text(document.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .allowsHitTesting(false)

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



            Menu {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button(color.label) { appearance.color = color }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("색상")

            Button(action: onToggleLevel) {
                Image(systemName: appearance.level == .floating ? "pin.fill" : "pin")
            }
            .help(appearance.level == .floating ? "바탕화면에 붙이기" : "항상 위에 띄우기")

            Button(action: onClose) { Image(systemName: "xmark") }
                .help("닫기 (파일은 그대로 남음)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.black.opacity(0.55))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(DragHandle())
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
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
