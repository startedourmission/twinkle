import AppKit
import SwiftUI

/// 말풍선 꼬리 위치. 창 크기가 바뀌면 다시 계산
@MainActor
final class BubbleLayout: ObservableObject {
    /// 꼬리 가운데의 x (말풍선 왼쪽 기준)
    @Published var tailX: CGFloat = 0
    /// true면 말풍선이 기준점 위에 있고 꼬리가 아래를 가리킴
    @Published var pointsDown = true
}

/// 화면의 한 점(로고 가운데)을 꼬리로 가리키는 말풍선 창.
/// NSPopover는 계속 움직이는 작은 딸린 창에 붙이면 위치를 엉뚱하게 잡아서 직접 만듦
final class BubblePanel: NSPanel, NSWindowDelegate {
    private let anchor: CGPoint
    private let gap: CGFloat
    private let layout = BubbleLayout()
    private let onClose: () -> Void

    static let tailHeight: CGFloat = 9

    init<Content: View>(content: Content, anchor: CGPoint, gap: CGFloat, onClose: @escaping () -> Void) {
        self.anchor = anchor
        self.gap = gap
        self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self
        let hosting = NSHostingController(rootView: BubbleView(layout: layout, content: content))
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }

    func present() {
        reposition()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// 기본은 기준점 위, 화면 위쪽이 모자라면 아래. 좌우는 화면 안으로 밀어 넣고 꼬리로 기준점을 가리킴
    private func reposition() {
        let size = frame.size
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .infinite
        let above = anchor.y + gap + size.height <= screen.maxY
        var x = anchor.x - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = above ? anchor.y + gap : anchor.y - gap - size.height
        setFrameOrigin(CGPoint(x: x, y: y))
        layout.pointsDown = above
        layout.tailX = min(max(anchor.x - x, 22), size.width - 22)
    }

    // 내용이 늘거나 줄면 꼬리가 기준점을 계속 가리키게 다시 배치
    func windowDidResize(_ notification: Notification) { reposition() }

    // 다른 곳을 누르면 닫힘
    func windowDidResignKey(_ notification: Notification) { close() }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose()
    }
}

private struct BubbleView<Content: View>: View {
    @ObservedObject var layout: BubbleLayout
    let content: Content

    private let fill = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(spacing: 0) {
            if !layout.pointsDown { tail.rotationEffect(.degrees(180)) }
            content
                .background(RoundedRectangle(cornerRadius: 12).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            if layout.pointsDown { tail }
        }
        .fixedSize()
    }

    private var tail: some View {
        Triangle()
            .fill(fill)
            .frame(width: 18, height: BubblePanel.tailHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, max(layout.tailX - 9, 0))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
