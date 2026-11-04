import AppKit
import CryptoKit
import LocalAuthentication
import UniformTypeIdentifiers

private final class AuthenticationRequest: @unchecked Sendable {
    let context = LAContext()
}

// Never vend the editor's text or selection through Accessibility.
final class PrivateTextView: NSTextView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityValue() -> String? { nil }
    override func accessibilitySelectedText() -> String? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
}

@MainActor
final class NoteController: NSViewController, NSTextViewDelegate {
    private enum State { case locked, unlocking, unlocked }
    var onLockStateChange: ((Bool) -> Void)?
    private var state = State.locked
    private var store: EncryptedStore?
    private var vault: PortableVault?
    private var creatingURL: URL?
    private let keychain = KeychainStore()
    private var key: SymmetricKey?
    private var context: LAContext?
    private var generation = 0
    private var pendingCiphertext: Data?
    private var encryptionFailed = false
    private let editor = PrivateTextView()
    private let scroll = NSScrollView()
    private let cover = NSView()
    private let fileLabel = NSTextField(labelWithString: "Your own little hiding place.")
    private let message = NSTextField(wrappingLabelWithString: "Create a stash or open an encrypted file.")
    private let status = NSTextField(labelWithString: "No file open")
    private let password = NSSecureTextField()
    private let confirmation = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "Remember on this Mac", target: nil, action: nil)
    private lazy var unlockButton = NSButton(title: "Unlock Stash", target: self, action: #selector(unlockWithPassword))
    private lazy var biometricButton = NSButton(title: "Touch ID or Mac password", target: self, action: #selector(unlockWithBiometrics))
    private lazy var lockButton = NSButton(title: "Lock", target: self, action: #selector(lockFromButton))

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func loadView() {
        view = StashBackgroundView(frame: NSRect(x: 0, y: 0, width: 680, height: 720))
        view.wantsLayer = true
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isIncrementalSearchingEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 24, height: 24)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.setAccessibilityElement(false)
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityElement(false)
        scroll.setAccessibilityChildren([])
        cover.wantsLayer = true
        let logo = NSImageView(image: BrandArtwork.image(size: 128))
        logo.setAccessibilityElement(false)
        logo.widthAnchor.constraint(equalToConstant: 104).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let title = NSTextField(labelWithString: "Tiny Stash")
        let titleFont = NSFont.systemFont(ofSize: 34, weight: .bold)
        title.font = titleFont.fontDescriptor.withDesign(.rounded).flatMap {
            NSFont(descriptor: $0, size: 34)
        } ?? titleFont
        title.textColor = .labelColor
        let tagline = NSTextField(labelWithString: "A little secure space")
        tagline.font = .systemFont(ofSize: 14)
        tagline.textColor = .secondaryLabelColor
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.textColor = .labelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        password.placeholderString = "File password"
        password.setAccessibilityLabel("File password")
        confirmation.placeholderString = "Confirm file password"
        confirmation.setAccessibilityLabel("Confirm file password")
        password.target = self
        password.action = #selector(unlockWithPassword)
        confirmation.target = self
        confirmation.action = #selector(unlockWithPassword)
        for field in [password, confirmation] {
            field.font = .systemFont(ofSize: 15)
            field.bezelStyle = .roundedBezel
            field.controlSize = .large
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        remember.font = .systemFont(ofSize: 12)
        remember.contentTintColor = .secondaryLabelColor
        remember.toolTip = "Enable Touch ID or your Mac password for this file using the device-only Keychain."
        let files = NSStackView(views: [
            NSButton(title: "New Stash…", target: self, action: #selector(newStash)),
            NSButton(title: "Open Stash…", target: self, action: #selector(openStash))
        ])
        files.spacing = 20
        for case let button as NSButton in files.arrangedSubviews {
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
        }
        message.alignment = .center
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 320
        message.widthAnchor.constraint(equalToConstant: 320).isActive = true
        unlockButton.bezelStyle = .rounded
        unlockButton.controlSize = .large
        unlockButton.bezelColor = BrandArtwork.pocket
        unlockButton.contentTintColor = BrandArtwork.paper
        unlockButton.font = .systemFont(ofSize: 14, weight: .semibold)
        unlockButton.widthAnchor.constraint(equalToConstant: 320).isActive = true
        unlockButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        biometricButton.isBordered = false
        biometricButton.attributedTitle = NSAttributedString(string: biometricButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
        biometricButton.contentTintColor = .labelColor
        biometricButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        biometricButton.imagePosition = .imageLeading
        let stack = NSStackView(views: [
            logo, title, tagline, fileLabel, password, confirmation,
            unlockButton, remember, biometricButton, message, files
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: logo)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(26, after: tagline)
        stack.setCustomSpacing(18, after: fileLabel)
        stack.setCustomSpacing(20, after: message)
        cover.addSubview(stack)
        let footer = NSStackView(views: [status, NSView(), lockButton])
        footer.spacing = 12
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for child in [scroll, cover, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            cover.topAnchor.constraint(equalTo: scroll.topAnchor),
            cover.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: cover.widthAnchor, constant: -48),
            fileLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        scroll.isHidden = true
        lockButton.isEnabled = false
        refreshControls()
    }

    private func refreshControls() {
        let selected = store != nil || creatingURL != nil
        fileLabel.isHidden = !selected
        password.isHidden = !selected
        confirmation.isHidden = creatingURL == nil
        remember.isHidden = !selected
        biometricButton.isHidden = vault == nil || creatingURL != nil
        unlockButton.isHidden = !selected
        unlockButton.title = creatingURL == nil ? "Unlock Stash" : "Create Stash"
        unlockButton.isEnabled = state == .locked
        biometricButton.isEnabled = state == .locked
        password.isEnabled = state == .locked
        confirmation.isEnabled = state == .locked
        remember.isEnabled = state == .locked
        lockButton.isHidden = state != .unlocked
        fileLabel.stringValue = (creatingURL ?? store?.url)?.lastPathComponent ?? "Your own little hiding place."
        view.window?.title = store.map { "\($0.url.lastPathComponent) — Tiny Stash" } ?? "Tiny Stash"
    }

    private func prepareToSwitch() -> Bool {
        lock()
        guard !hasUnsavedEdits else {
            message.stringValue = "Save failed. Unlock this stash to retry before opening another. Do not quit."
            return false
        }
        return true
    }

    @objc func newStash() {
        guard prepareToSwitch() else { return }
        let panel = NSSavePanel()
        panel.title = "Create an encrypted stash"
        panel.nameFieldStringValue = "My Stash.tinystash"
        panel.allowedContentTypes = [UTType(filenameExtension: "tinystash") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            message.stringValue = "Choose a new filename. New Stash never replaces an existing file."
            return
        }
        store = nil
        vault = nil
        creatingURL = url
        message.stringValue = "Choose a strong, unique file password. It travels with the file's encryption. There is no password reset."
        refreshControls()
        view.window?.makeFirstResponder(password)
    }

    @objc func openStash() {
        guard prepareToSwitch() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tinystash") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    func openFile(_ url: URL) {
        _ = view
        guard prepareToSwitch() else { return }
        do {
            let target = EncryptedStore(url: url)
            let selected = try PortableVault(data: target.readSealed())
            store = target
            vault = selected
            creatingURL = nil
            message.stringValue = "Enter this file's password. Touch ID works only if enabled on this Mac."
            status.stringValue = "Locked"
            refreshControls()
            view.window?.makeFirstResponder(password)
        } catch {
            message.stringValue = "Could not open this stash. \(error.localizedDescription) The file has not been changed."
        }
    }

    @objc private func unlockWithPassword() {
        guard state == .locked, NSApp.isActive, view.window?.isMiniaturized == false else { return }
        let secret = password.stringValue
        guard !secret.isEmpty else { message.stringValue = "Enter the file password."; return }
        if creatingURL != nil {
            guard secret == confirmation.stringValue else { message.stringValue = "Passwords do not match."; return }
        }
        let shouldRemember = remember.state == .on
        password.stringValue = ""
        confirmation.stringValue = ""
        state = .unlocking
        generation += 1
        let attempt = generation
        let destination = creatingURL
        let selected = vault
        refreshControls()
        message.stringValue = destination == nil ? "Unlocking…" : "Creating encrypted stash…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> (PortableVault, SymmetricKey, Data?) in
                if destination != nil {
                    let created = try PortableVault.create(password: secret)
                    return (created.vault, created.key, try created.vault.seal("", using: created.key))
                }
                guard let selected else { throw CocoaError(.fileReadUnknown) }
                return (selected, try selected.unlock(password: secret), nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.accepts(attempt) else { return }
                do {
                    let (document, key, initial) = try result.get()
                    if let destination, let initial {
                        let target = EncryptedStore(url: destination)
                        try target.saveSealed(initial, createOnly: true)
                        self.store = target
                        self.vault = document
                        self.creatingURL = nil
                    }
                    try self.reveal(using: key)
                    if shouldRemember { self.rememberKey(key, document: document, attempt: attempt) }
                } catch {
                    self.finishFailedUnlock("Could not unlock or create this stash. \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func unlockWithBiometrics() {
        guard state == .locked, let vault, NSApp.isActive, view.window?.isMiniaturized == false else { return }
        state = .unlocking
        generation += 1
        let attempt = generation
        let request = AuthenticationRequest()
        request.context.localizedCancelTitle = "Keep locked"
        context = request.context
        password.stringValue = ""
        refreshControls()
        message.stringValue = "Waiting for authentication…"
        let keychain = self.keychain
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try keychain.unlock(id: vault.id, context: request.context) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.accepts(attempt) else { request.context.invalidate(); return }
                do { try self.reveal(using: result.get()) }
                catch { self.finishFailedUnlock("Could not unlock. \(error.localizedDescription) You can use the file password instead.") }
            }
        }
    }

    private func accepts(_ attempt: Int) -> Bool {
        generation == attempt && state == .unlocking && NSApp.isActive && view.window?.isMiniaturized == false
    }

    private func reveal(using key: SymmetricKey) throws {
        guard let store, let vault else { throw CocoaError(.fileReadUnknown) }
        let text: String
        var recoveryWarning: String?
        if let pendingCiphertext {
            // Pending data authenticates independently of a missing/damaged
            // disk copy. A failed retry must not prevent copying out the text.
            text = try vault.load(pendingCiphertext, using: key)
            do {
                _ = try vault.load(store.readSealed(), using: key)
                try store.saveSealed(pendingCiphertext)
                self.pendingCiphertext = nil
            } catch {
                recoveryWarning = "Unsaved edits recovered • copy the text somewhere safe; saving still fails."
            }
        } else if encryptionFailed {
            _ = try vault.load(store.readSealed(), using: key)
            text = editor.string
            pendingCiphertext = try vault.seal(text, using: key)
            recoveryWarning = "Unsaved edits recovered • copy the text somewhere safe."
        } else {
            text = try vault.load(store.readSealed(), using: key)
        }
        self.key = key
        editor.string = text
        editor.undoManager?.removeAllActions()
        encryptionFailed = false
        state = .unlocked
        context?.invalidate()
        context = nil
        cover.isHidden = true
        scroll.isHidden = false
        lockButton.isEnabled = true
        status.stringValue = recoveryWarning ?? "Encrypted file"
        refreshControls()
        onLockStateChange?(true)
        view.window?.makeFirstResponder(editor)
    }

    private func rememberKey(_ key: SymmetricKey, document: PortableVault, attempt: Int) {
        let keychain = self.keychain
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try keychain.remember(key, id: document.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == attempt, self.state == .unlocked else { return }
                if case .failure(let error) = result {
                    self.status.stringValue = "File saved; local unlock not enabled. \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishFailedUnlock(_ text: String) {
        state = .locked
        context?.invalidate()
        context = nil
        refreshControls()
        message.stringValue = text
    }

    func textDidChange(_ notification: Notification) {
        guard state == .unlocked else { return }
        saveEdits()
    }

    private func saveEdits() {
        guard let key, let store, let vault else { return }
        do {
            pendingCiphertext = try vault.seal(editor.string, using: key)
            encryptionFailed = false
        } catch {
            // The hidden editor now holds the newest edit. Older ciphertext
            // must not take precedence over it when the user unlocks again.
            pendingCiphertext = nil
            encryptionFailed = true
            status.stringValue = "Encryption failed. Edits held in memory; do not quit."
            return
        }
        do {
            try store.saveSealed(pendingCiphertext!)
            pendingCiphertext = nil
            status.stringValue = "Saved encrypted"
        } catch {
            status.stringValue = "Save failed. Edits held encrypted in memory; do not quit."
        }
    }

    @objc private func lockFromButton() { lock() }

    func lock() {
        guard isViewLoaded else { return }
        cover.isHidden = false
        scroll.isHidden = true
        view.window?.makeFirstResponder(nil)
        view.displayIfNeeded()
        if state == .unlocked { saveEdits() }
        generation += 1
        state = .locked
        context?.invalidate()
        context = nil
        key = nil
        password.stringValue = ""
        confirmation.stringValue = ""
        remember.state = .off
        if !encryptionFailed { editor.string = "" }
        editor.undoManager?.removeAllActions()
        lockButton.isEnabled = false
        let unsaved = hasUnsavedEdits
        status.stringValue = unsaved ? "Locked • unsaved edits in memory; do not quit" : (store == nil ? "No file open" : "Locked")
        message.stringValue = unsaved
            ? "Edits could not be saved. Unlock to retry. Keep Tiny Stash open to preserve them."
            : (store == nil && creatingURL == nil ? "Create a stash or open an encrypted file." : "Enter the file password to unlock.")
        refreshControls()
        onLockStateChange?(false)
    }

    var hasUnsavedEdits: Bool { pendingCiphertext != nil || encryptionFailed }
}
