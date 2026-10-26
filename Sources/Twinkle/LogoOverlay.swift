import AppKit
import SwiftUI

/// 로고가 가야 할 화면 위치와, 로고를 딸린 창으로 붙일 메모 창
struct LogoAnchor {
    var point: CGPoint
    /// 로고는 이 메모의 딸린 창이 되어 항상 메모 바로 위에 그려짐 (다른 앱 창 위로 튀어나오지 않게)
    weak var parent: NSWindow?
}

enum LogoFlash: Equatable {
    case none, success, failure, question
}

@MainActor
final class AgentLogoModel: ObservableObject {
    let kind: AgentKind
    @Published var image: NSImage?
    @Published var isWorking = false
    @Published var flash: LogoFlash = .none
    /// 사용량 한도 대비 사용률 (0~1). nil이면 테두리 없음
    @Published var usage: Double?
    /// 로고 클릭 → 상세 작업 내역
    var onTap: (() -> Void)?

    init(kind: AgentKind) {
        self.kind = kind
    }
}

/// 비활성 창이어도 첫 클릭을 바로 받음
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 로고 하나 = 로고 크기만 한 작은 투명 창 하나. 클릭하면 상세 내역
private final class LogoWindow: NSPanel {
    init(model: AgentLogoModel) {
        super.init(
            contentRect: CGRect(origin: .zero, size: LogoDirector.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = ClickThroughHostingView(rootView: AgentLogoView(model: model))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
}

/// 로고들을 스프링처럼 따라 움직이게 하는 감독.
/// 쉬는 동안엔 메인 메모 위에서 동동 떠 있고, 일을 맡으면 그 todo 줄 옆으로 날아감
@MainActor
final class LogoDirector: NSObject, NSPopoverDelegate {
    static let windowSize = CGSize(width: 60, height: 60)
    /// 창 안에서 로고 중심이 있는 위치
    static let logoCenter = CGPoint(x: 30, y: 30)

    /// 일하는 중인 에이전트가 가리킬 위치. nil이면 쉬는 자리로
    var workAnchor: ((AgentJob) -> LogoAnchor?)?
    /// 쉬는 자리 (메인 메모 위쪽). index는 에이전트 순번
    var idleAnchor: ((Int) -> LogoAnchor?)?

    private let runner: AgentRunner
    private var models: [AgentKind: AgentLogoModel] = [:]
    private var windows: [AgentKind: LogoWindow] = [:]
    private var positions: [AgentKind: CGPoint] = [:]
    private var velocities: [AgentKind: CGVector] = [:]
    private var anchors: [AgentKind: LogoAnchor] = [:]
    private var timer: Timer?
    private var tickCount = 0
    private var detailsPopover: NSPopover?
    /// 상세 내역이 열려 있는 로고는 다른 창들 위로 올려 둠
    private var detailsKind: AgentKind?

    init(runner: AgentRunner) {
        self.runner = runner
        super.init()
        for kind in AgentKind.allCases {
            let model = AgentLogoModel(kind: kind)
            model.image = AgentLogos.image(for: kind)
            model.onTap = { [weak self] in self?.showDetails(kind) }
            models[kind] = model
            windows[kind] = LogoWindow(model: model)
        }
        runner.onJobFinished = { [weak self] kind, state in
            self?.flash(kind, state == .done ? .success : state == .waiting ? .question : .failure)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        detailsPopover?.close()
        windows.values.forEach { $0.orderOut(nil) }
        runner.onJobFinished = nil
    }

    private func showDetails(_ kind: AgentKind) {
        guard let window = windows[kind], let content = window.contentView else { return }
        detailsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: JobDetailView(kind: kind, runner: runner))
        detailsKind = kind
        NSApp.activate()
        // 기준은 로고 원 자체(창 전체 말고)라 꼬리가 로고 가운데를 가리킴. 기본은 위쪽에 띄움
        // (호스팅 뷰는 위가 0인 좌표라 위쪽 = minY. 자리가 없으면 macOS가 아래로 뒤집음)
        let circle = NSRect(x: Self.logoCenter.x - 18, y: Self.logoCenter.y - 18, width: 36, height: 36)
        popover.show(relativeTo: circle, of: content, preferredEdge: content.isFlipped ? .minY : .maxY)
        detailsPopover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        detailsKind = nil
        detailsPopover = nil
    }

    private func flash(_ kind: AgentKind, _ flash: LogoFlash) {
        models[kind]?.flash = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                if self?.models[kind]?.flash == flash { self?.models[kind]?.flash = .none }
            }
        }
    }

    private func tick() {
        tickCount += 1
        // 위치 계산(텍스트 레이아웃 조회)은 10Hz, 움직임은 60Hz
        if tickCount % 6 == 1 { refreshAnchors() }

        for (index, kind) in AgentKind.allCases.enumerated() {
            guard let window = windows[kind], let model = models[kind] else { continue }
            let job = runner.jobs[kind]
            let enabled = AppSettings.shared.settings(for: kind).enabled
            let visible = (enabled && runner.isEnabled || job != nil || model.flash != .none || detailsKind == kind) && anchors[kind] != nil

            if model.isWorking != (job != nil) { model.isWorking = job != nil }
            let monitor = UsageMonitor.shared
            let usage = monitor.showsRing ? monitor.usage[kind].map { ($0.fraction * 100).rounded() / 100 } : nil
            if model.usage != usage { model.usage = usage }

            guard visible, let anchor = anchors[kind], let parent = anchor.parent else {
                window.parent?.removeChildWindow(window)
                if window.isVisible { window.orderOut(nil) }
                positions[kind] = nil
                continue
            }

            if window.parent !== parent {
                window.parent?.removeChildWindow(window)
                parent.addChildWindow(window, ordered: .above)
            }
            let target = anchor.point
            var position = positions[kind] ?? CGPoint(x: target.x, y: target.y - 40 - CGFloat(index) * 10)
            var velocity = velocities[kind] ?? .zero

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                position = target
                velocity = .zero
            } else {
                // 감쇠 스프링: 멀리 있으면 휙 날아가고, 도착하면 살짝 출렁이다 멈춤
                let stiffness = 0.018, damping = 0.86
                velocity.dx = velocity.dx * damping + (target.x - position.x) * stiffness
                velocity.dy = velocity.dy * damping + (target.y - position.y) * stiffness
                position.x += velocity.dx
                position.y += velocity.dy
            }
            positions[kind] = position
            velocities[kind] = velocity

            let origin = CGPoint(x: (position.x - Self.logoCenter.x).rounded(), y: (position.y - Self.logoCenter.y).rounded())
            if window.frame.origin != origin { window.setFrameOrigin(origin) }
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    private func refreshAnchors() {
        for (index, kind) in AgentKind.allCases.enumerated() {
            if let job = runner.jobs[kind], let anchor = workAnchor?(job) {
                anchors[kind] = anchor
            } else {
                anchors[kind] = idleAnchor?(index)
            }
        }
    }
}

/// 에이전트 로고 이미지.
/// 1) ~/Library/Application Support/Twinkle/logos/<kind>.png (사용자가 바꾸고 싶을 때)
/// 2) 앱에 포함된 공식 로고 (Resources/logos, 출처: LobeHub Icons)
/// 3) 설치된 공식 앱 아이콘
@MainActor
enum AgentLogos {
    static var overrideDirectory: URL? {
        didSet { cache.removeAll() }
    }
    private static var cache: [AgentKind: NSImage] = [:]

    /// .app 안의 Contents/Resources/logos, `swift run`일 때는 저장소의 Resources/logos
    private static let bundledDirectories: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("logos"),
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/logos"),
    ].compactMap { $0 }

    static func image(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = load(kind)
        cache[kind] = image
        return image
    }

    private static func load(_ kind: AgentKind) -> NSImage? {
        let directories = [overrideDirectory].compactMap { $0 } + bundledDirectories
        for directory in directories {
            for ext in ["png", "jpg", "jpeg", "pdf", "icns"] {
                if let image = NSImage(contentsOf: directory.appendingPathComponent("\(kind.rawValue).\(ext)")) {
                    return image
                }
            }
        }
        let bundleIDs: [String] = switch kind {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .grok: ["ai.x.grok", "com.xai.grok"]
        }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

private struct AgentLogoView: View {
    @ObservedObject var model: AgentLogoModel

    private let size: CGFloat = 36
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            logo(time: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: LogoDirector.windowSize.width, height: LogoDirector.windowSize.height)
        .contentShape(Circle().inset(by: 10))
        .onTapGesture { model.onTap?() }
        .help("\(model.kind.displayName) — 클릭하면 작업 내역")
        .animation(.spring(duration: 0.3), value: model.flash)
    }

    /// 시간으로 직접 계산하는 움직임: 쉴 땐 천천히 동동, 일할 땐 빠르게 까딱이며 파동을 냄
    private func logo(time: Double) -> some View {
        let working = model.isWorking
        let bob = reduceMotion ? 0 : sin(time * (working ? 7 : 2.2)) * (working ? 2 : 3.5)
        let tilt = reduceMotion || !working ? 0 : sin(time * 9) * 7
        let pulse = (time.truncatingRemainder(dividingBy: 1.2)) / 1.2

        return ZStack {
            if working {
                Circle()
                    .stroke(Color(nsColor: model.kind.color), lineWidth: 2)
                    .frame(width: size + 6, height: size + 6)
                    .scaleEffect(1 + pulse * 0.35)
                    .opacity(0.8 * (1 - pulse))
            }

            if let usage = model.usage {
                // 사용량 테두리: 12시 방향부터 시계 방향, 많이 쓸수록 초록 → 주황 → 빨강
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 3)
                    .frame(width: size + 7, height: size + 7)
                Circle()
                    .trim(from: 0, to: max(min(usage, 1), 0.02))
                    .stroke(Self.usageColor(usage), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 7, height: size + 7)
            }

            face
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .rotationEffect(.degrees(tilt))

            if model.flash != .none {
                Image(systemName: flashSymbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white, flashColor)
                    .offset(x: 14, y: -14)
                    .transition(.scale)
            }
        }
        .offset(y: bob)
    }

    static func usageColor(_ usage: Double) -> Color {
        usage >= 0.85 ? .red : usage >= 0.6 ? .orange : .green
    }

    private var flashSymbol: String {
        switch model.flash {
        case .success: "checkmark.circle.fill"
        case .question: "questionmark.circle.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    private var flashColor: Color {
        switch model.flash {
        case .success: .green
        case .question: .purple
        default: .red
        }
    }

    @ViewBuilder
    private var face: some View {
        if let image = model.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.16)
                .background(Color.white)
        } else {
            ZStack {
                Color(nsColor: model.kind.color)
                Image(systemName: model.kind.symbolName)
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}
