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
    var onOpenLink: (String) -> Void
    var onNew: () -> Void
    var onShowTodos: () -> Void
    var onToggleLevel: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            MarkdownEditor(document: document, onOpenLink: onOpenLink)
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
            Text(document.name)
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

            Button(action: onShowTodos) { Image(systemName: "checklist") }
                .help("할 일 모아보기")

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

/// 로고 자리 임시 배지 (나중에 실제 로고 이미지로 교체)
struct AgentBadge: View {
    let kind: AgentKind
    var size: CGFloat = 18

    var body: some View {
        Text(kind.badgeLetter)
            .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: kind.color)))
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
