import Darwin
import Foundation
import XCTest
@testable import TinyStash

final class EncryptedStoreTests: XCTestCase {
    private func withStore(_ body: (EncryptedStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyStashTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(EncryptedStore(url: directory.appendingPathComponent("note.tinystash")))
    }

    func testSavePreservesExactBytesAndReplacesByDefault() throws {
        try withStore { store in
            let first = Data([0x00, 0xff, 0x7f, 0x10])
            try store.saveSealed(first)
            XCTAssertEqual(try Data(contentsOf: store.url), first)
            let replacement = Data([0x42, 0x00, 0x13])
            try EncryptedStore(url: store.url).saveSealed(replacement)
            XCTAssertEqual(try Data(contentsOf: store.url), replacement)
        }
    }

    func testWriterSupportsEmptyDataWithoutLeavingTemporaryFiles() throws {
        try withStore { store in
            try store.saveSealed(Data(), createOnly: true)
            XCTAssertEqual(try Data(contentsOf: store.url), Data())
            let names = try FileManager.default.contentsOfDirectory(
                atPath: store.url.deletingLastPathComponent().path
            )
            XCTAssertEqual(names, [store.url.lastPathComponent])
        }
    }

    func testFailedSavePreservesPreviousBytes() throws {
        try withStore { store in
            let previous = Data([0x00, 0x11, 0xff])
            try store.saveSealed(previous)

            // Immutable destinations reject replacement at the atomic commit.
            guard chflags(store.url.path, UInt32(UF_IMMUTABLE)) == 0 else {
                throw XCTSkip("The test filesystem does not support immutable file flags.")
            }
            defer { _ = chflags(store.url.path, 0) }
            XCTAssertThrowsError(try store.saveSealed(Data([0x22, 0x33])))
            XCTAssertEqual(try Data(contentsOf: store.url), previous)
            let names = try FileManager.default.contentsOfDirectory(
                atPath: store.url.deletingLastPathComponent().path
            )
            XCTAssertEqual(names, [store.url.lastPathComponent])
        }
    }

    func testSaveUsesPrivateNewDirectoryAndFilePermissions() throws {
        try withStore { store in
            try store.saveSealed(Data([0x00, 0xff]))
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: store.url.deletingLastPathComponent().path
            )
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testCreateOnlyPublishesNewFileAndRefusesReplacement() throws {
        try withStore { store in
            let original = Data([0x00, 0x11, 0xff])
            try store.saveSealed(original, createOnly: true)
            let replacement = Data([0x22, 0x33])
            XCTAssertThrowsError(try store.saveSealed(replacement, createOnly: true)) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(error.code, Int(EEXIST))
            }
            XCTAssertEqual(try Data(contentsOf: store.url), original)
            let names = try FileManager.default.contentsOfDirectory(
                atPath: store.url.deletingLastPathComponent().path
            )
            XCTAssertEqual(names, [store.url.lastPathComponent])

            try store.saveSealed(replacement)
            XCTAssertEqual(try Data(contentsOf: store.url), replacement)
        }
    }

    func testCreateOnlyRefusesSymlinkWithoutChangingItsTarget() throws {
        try withStore { store in
            let directory = store.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("existing")
            let original = Data("Existing user data".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
            XCTAssertThrowsError(try store.saveSealed(Data([1, 2, 3]), createOnly: true))
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: store.url.path),
                target.path
            )
        }
    }

    func testCreateOnlyRefusesExistingDirectory() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
            XCTAssertThrowsError(try store.saveSealed(Data([1, 2, 3]), createOnly: true))
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        }
    }

    func testSavingPreservesExistingParentPermissions() throws {
        try withStore { store in
            let directory = store.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: directory.path)
            for createOnly in [true, false] {
                try store.saveSealed(Data([0x00, 0xff]), createOnly: createOnly)
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
                XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }
    }

    func testBoundedReaderPreservesBytesAtLimit() throws {
        try withStore { store in
            let bytes = Data(repeating: 0xa5, count: EncryptedStore.maximumFileSize)
            try store.saveSealed(bytes, createOnly: true)
            XCTAssertEqual(try store.readSealed(), bytes)
        }
    }

    func testOversizedReadAndSaveAreRejectedWithoutReplacingFile() throws {
        try withStore { store in
            let original = Data([1, 2, 3])
            try store.saveSealed(original)
            let oversized = Data(repeating: 0, count: EncryptedStore.maximumFileSize + 1)
            XCTAssertThrowsError(try store.saveSealed(oversized))
            XCTAssertEqual(try store.readSealed(), original)
            try oversized.write(to: store.url)
            XCTAssertThrowsError(try store.readSealed())
        }
    }

    func testReaderRejectsFIFOWithoutWaitingForWriter() throws {
        try withStore { store in
            try FileManager.default.createDirectory(
                at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            XCTAssertEqual(mkfifo(store.url.path, 0o600), 0)
            XCTAssertThrowsError(try store.readSealed())
        }
    }
}
