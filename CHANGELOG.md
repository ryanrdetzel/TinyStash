# Changelog

## Unreleased

- Add an actual-app screenshot and explain the sensitive development/testing scratchpad use case, including the limits of protection from AI agents and other local processes.
- Prepare the public Tiny Stash repository with MIT licensing, contributor/agent guidance, and public-facing documentation without private project links.
- Restore Settings (⌘,) with persistent lock-on-focus-loss and System/Light/Dark appearance choices. Apply appearance to the lock screen, editor, and Settings window; keep minimizing, sleep, and system locking unconditional.
- Remember the editor's window size and position across locking and launches. Keep lock-screen resizing separate from the saved editor frame, and allow the editor to shrink below the lock screen's minimum size.
- Added a shared vector pocket-and-note logo, a full-resolution macOS application icon, and a reproducible icon generator. Redesigned the lock screen with an ink-blue palette, rounded wordmark, clearer unlock hierarchy, and compact secondary actions.
- Fixed a recovery data-loss path where older pending ciphertext could replace newer text after an encryption failure.
- Allow authenticated pending edits to be recovered for copying even when retrying the save fails or the original disk file is missing/damaged; retain unsaved-edit quit/switch protection.
- Bound encrypted file reads and writes to 16 MiB and reject non-regular input files, including FIFOs, without waiting for a writer.
- Added explicit Developer ID notarization, ticket stapling and Gatekeeper-verified distribution archives. Verify packaged signatures, stage fresh bundles, and keep provisioning optional for password-only builds.
- Ignore common credential/signing artifacts and personal notes. Gitleaks reported no leaks in the working tree or available Git history.
- Rebranded the app to Tiny Stash across the window, locked screen, menus, alerts, bundle metadata, Swift targets, source paths, and build instructions. The packaged app is now `build/Tiny Stash.app`.
- Added New/Open Stash, user-selected `.tinystash` locations, Finder opening, and password confirmation. A self-contained versioned envelope uses PBKDF2-HMAC-SHA256 (600,000 iterations) to wrap an independent random AES-256-GCM content key; the same file password works after moving or renaming the file without Keychain access.
- Added opt-in per-file Touch ID/Mac-password convenience keys, protected by user presence in the device-only Data Protection Keychain. Password-based file access does not require provisioning.
- Preserved automatic locking, private per-edit atomic autosave, stale-unlock rejection, failed-save recovery, and refusal to quit or switch files with pending edits. New-file publication cannot overwrite an existing destination; user-selected parent-folder permissions are left unchanged.
- Left the original bundle identifier, legacy ciphertext, and legacy Keychain entries untouched. Legacy notes still require their original key and are not automatically converted.
- Verified portable-format/storage behavior and an isolated actual-app create/unlock/edit/save/lock/move/reopen flow, including wrong-password rejection and failed-save recovery. Successful biometric authentication still requires interactive verification on a provisioned build.

## 0.1.0 — 2026-10-30

- Created Fold as a local, dependency-free Swift/AppKit encrypted note app.
- Added a single private editor, explicit authenticated unlock, encrypted per-edit autosave, and immediate lifecycle locking with stale-authentication rejection.
- Added AES-GCM ciphertext storage, private atomic writes, and user-presence-protected Data Protection Keychain key handling.
- Retained encrypted pending edits on save failure and prevented ordinary quit/close from silently losing them.
- Added native app packaging, Hardened Runtime signing, provisioning-profile support, and 12 passing encrypted-storage tests.
- Verified controller lock/save/recovery transitions with an isolated fake-authentication smoke run and inspected the actual locked app visually and through Accessibility.
- Real authenticated vault verification remains blocked on a matching macOS provisioning profile. The default ad-hoc bundle is for UI inspection only; use fake secrets.
