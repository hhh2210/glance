import AppKit

/// A cancel button needs a real interactive panel; the lock-screen notch is
/// intentionally click-through. This panel neither becomes key nor activates Glance.
@MainActor
final class AutoFillApprovalPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: NSPanel?
    private var label: NSTextField?
    private var onCancel: (() -> Void)?

    func show(near bounds: CGRect, cancel: @escaping () -> Void) {
        dismiss()
        onCancel = cancel
        let size = NSSize(width: 350, height: 100)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let target = NSRect(x: bounds.minX, y: desktopTop - bounds.maxY, width: bounds.width, height: bounds.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) }) else { return }
        let area = screen.visibleFrame
        let frame = NSRect(
            x: min(max(target.midX - size.width / 2, area.minX + 12), area.maxX - size.width - 12),
            y: max(area.minY + 12, target.minY - size.height - 12), width: size.width, height: size.height
        )
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glance AutoFill approval"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        panel.contentView = content

        let title = NSTextField(labelWithString: "Glance · AutoFill")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 18, y: 65, width: 230, height: 18)
        content.addSubview(title)
        let label = NSTextField(wrappingLabelWithString: "Looking for your face…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 18, y: 15, width: 220, height: 42)
        content.addSubview(label)
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 255, y: 30, width: 78, height: 32)
        content.addSubview(button)
        self.panel = panel
        self.label = label
        panel.orderFrontRegardless()
    }

    func update(_ message: String) { label?.stringValue = message }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
        onCancel = nil
    }

    @objc private func cancelPressed() { onCancel?() }
}
