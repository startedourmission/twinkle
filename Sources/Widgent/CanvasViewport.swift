import AppKit
import SwiftUI

/// 화면 좌표 = 월드 좌표 × scale + offset
struct Viewport {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(origin: toScreen(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    mutating func zoom(by factor: CGFloat, around point: CGPoint) {
        let newScale = min(max(scale * factor, 0.15), 3)
        let ratio = newScale / scale
        offset.width = point.x - (point.x - offset.width) * ratio
        offset.height = point.y - (point.y - offset.height) * ratio
        scale = newScale
    }

    mutating func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 60) {
        guard !rect.isNull, rect.width > 0 || rect.height > 0, size.width > 0 else { return }
        let available = CGSize(width: max(size.width - padding * 2, 50), height: max(size.height - padding * 2, 50))
        scale = min(max(min(available.width / max(rect.width, 1), available.height / max(rect.height, 1)), 0.15), 1.2)
        offset = CGSize(width: size.width / 2 - rect.midX * scale, height: size.height / 2 - rect.midY * scale)
    }

    /// 트랙패드 두 손가락 스크롤은 이동, ⌘+스크롤이나 마우스 휠은 확대/축소 (옵시디언과 같은 감각)
    mutating func handleScroll(_ event: NSEvent, at point: CGPoint) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            zoom(by: exp(step), around: point)
        } else {
            offset.width += event.scrollingDeltaX
            offset.height += event.scrollingDeltaY
        }
    }
}

/// SwiftUI에는 스크롤 휠 이벤트가 없어서, 창의 이벤트를 엿보다가 이 영역 안의 스크롤만 넘겨줌
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void

    final class CatcherView: NSView {
        var onScroll: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // 로컬 모니터는 항상 메인 스레드에서 불림
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.window === self.window else { return false }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return false }
                    self.onScroll?(event, point)
                    return true
                }
                return handled ? nil : event
            }
        }

        // 클릭은 위의 SwiftUI 뷰들이 받도록 통과
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }
}
