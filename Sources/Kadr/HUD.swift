import AppKit
import SwiftUI

/// Small transient message at the top of the active screen.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", detail: String? = nil, seconds: Double = 1.8) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let view = HUDView(text: text, symbol: symbol, detail: detail)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.withMouse
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = Exclusion.identifier
        p.isReleasedWhenClosed = false
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                    Task { @MainActor in p.orderOut(nil) }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func error(_ text: String) { show(text, symbol: "exclamationmark.triangle.fill", seconds: 3) }
}

private struct HUDView: View {
    let text: String
    let symbol: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(3).frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.82)))
    }
}

/// Big countdown in the middle of the screen (self-timer, recording start).
@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen = .withMouse) async {
        guard seconds > 0 else { return }
        let size = CGSize(width: 160, height: 160)
        let p = NSPanel(contentRect: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = Exclusion.identifier
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for n in stride(from: seconds, through: 1, by: -1) {
            p.contentView = NSHostingView(rootView:
                Text("\(n)").font(.system(size: 84, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: size.width, height: size.height)
                    .background(Circle().fill(Color.black.opacity(0.7))))
            p.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        p.orderOut(nil)
        try? await Task.sleep(nanoseconds: 120_000_000)  // let the window server drop the panel
    }
}
