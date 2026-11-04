# Tiny Stash contributor guidance

## Project

Tiny Stash is a dependency-free macOS 14+ Swift 6/AppKit app for a single encrypted plain-text note per user-selected `.tinystash` file. Read `README.md` for build, file-format, signing, and security boundaries. Source and tests live in `Sources/TinyStash` and `Tests/TinyStashTests`.

## Commands

- `swift test` — cryptographic format and filesystem behavior tests.
- `bash scripts/build.sh release` — package and strictly verify an ad-hoc signed `build/Tiny Stash.app`.
- `open "build/Tiny Stash.app"` — launch the native app for a smoke check with fake notes/passwords.
- `gitleaks dir . --redact` and `gitleaks git . --redact` — scan working files and Git history before publication (requires Gitleaks).

Notarization and authenticated Keychain unlock require external Apple credentials/provisioning. Never claim those paths work based only on an ad-hoc build or password-unlock tests.

## Security invariants

- Never commit real notes, passwords, private keys, signing identities, provisioning profiles, credentials, or local absolute paths. Keep signing material outside the repository and use fake data for verification.
- Preserve authenticated encryption, bounded file reads, private file permissions, atomic saves, and no-clobber creation. Never write plaintext notes or passwords to disk or logs.
- Preserve pending edits on encryption/save failure, and refuse ordinary quit or file switches while edits remain unsaved.
- Locking must hide the editor, clear its text/undo history where recovery permits, release the key, and invalidate asynchronous unlock results. Minimize/sleep/session/screen locking stays unconditional.
- Password portability must not depend on Keychain enrollment. Keep the existing bundle identifier and Keychain identifiers stable unless a deliberate migration is included.
- File-format changes require explicit versioning and compatibility decisions; reject malformed or unsupported input before expensive derivation.

## Changes and verification

Follow the existing Swift/AppKit conventions and keep UI work on the main actor. Avoid dependencies unless they solve a demonstrated need. Add focused regression coverage for consumer-visible cryptographic, persistence, or recovery changes. Run `swift test` and the packaged build, then exercise affected native UI flows with fake data; report credential-dependent paths separately. Update `README.md` and `CHANGELOG.md` when behavior, build instructions, or security boundaries change. Contributions are covered by the repository's MIT license.
