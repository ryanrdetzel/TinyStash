import AppKit

@MainActor
final class SettingsController: NSWindowController {
    private let defaults: UserDefaults
    private let onChange: () -> Void
    private let focusLock = NSButton(checkboxWithTitle: "Lock when Tiny Stash loses focus", target: nil, action: nil)
    private let appearancePicker = NSPopUpButton()
    private let appearanceValues = ["system", "light", "dark"]

    var locksOnFocusLoss: Bool { defaults.bool(forKey: "lockOnFocusLoss") }
    var appearance: NSAppearance? {
        switch defaults.string(forKey: "appearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        defaults.register(defaults: ["lockOnFocusLoss": true, "appearance": "system"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        focusLock.state = locksOnFocusLoss ? .on : .off
        focusLock.target = self
        focusLock.action = #selector(changeFocusLock)
        appearancePicker.addItems(withTitles: ["System", "Light", "Dark"])
        let selected = defaults.string(forKey: "appearance") ?? "system"
        appearancePicker.selectItem(at: appearanceValues.firstIndex(of: selected) ?? 0)
        appearancePicker.target = self
        appearancePicker.action = #selector(changeAppearance)
        let appearanceRow = NSStackView(views: [NSTextField(labelWithString: "Appearance"), appearancePicker])
        appearanceRow.spacing = 16
        let explanation = NSTextField(wrappingLabelWithString:
            "Sleep, screen lock, and minimizing always lock your stash. "
            + "Turning off focus locking leaves your text visible when you switch apps.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [appearanceRow, focusLock, explanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Use init(defaults:onChange:)") }

    @objc private func changeFocusLock() {
        defaults.set(focusLock.state == .on, forKey: "lockOnFocusLoss")
        onChange()
    }

    @objc private func changeAppearance() {
        defaults.set(appearanceValues[appearancePicker.indexOfSelectedItem], forKey: "appearance")
        onChange()
    }
}

@MainActor
final class StashBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? BrandArtwork.ink : BrandArtwork.paper).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
