import Foundation
import XCTest

final class BetterMenuCoreServiceTests: XCTestCase {
  func testFileCreatorWritesContentsAndGeneratesNonconflictingNames() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let definition = FileDefinition(
      id: "log",
      title: "LOG",
      menuTitle: "新建 LOG 文件",
      baseName: "新建日志",
      pathExtension: "log",
      text: "initial contents\n",
      enabledByDefault: false
    )

    let firstUrl = try FileCreator.createFile(
      from: definition,
      at: directoryUrl,
      bundle: Bundle(for: Self.self)
    )
    let secondUrl = try FileCreator.createFile(
      from: definition,
      at: directoryUrl,
      bundle: Bundle(for: Self.self)
    )

    XCTAssertEqual(firstUrl.lastPathComponent, "新建日志.log")
    XCTAssertEqual(secondUrl.lastPathComponent, "新建日志 2.log")
    XCTAssertEqual(try String(contentsOf: firstUrl, encoding: .utf8), "initial contents\n")
  }

  func testFileCreatorAppliesExecutablePermission() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let definition = FileDefinition(
      id: "sh",
      title: "Shell",
      menuTitle: "新建 Shell 文件",
      baseName: "script",
      pathExtension: "sh",
      text: "#!/usr/bin/env bash\n",
      shouldBeExecutable: true,
      enabledByDefault: false
    )

    let fileUrl = try FileCreator.createFile(
      from: definition,
      at: directoryUrl,
      bundle: Bundle(for: Self.self)
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: fileUrl.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

    XCTAssertEqual(permissions.intValue & 0o777, 0o755)
  }

  func testFileTransferCopiesFileAndReportsProgress() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceDirectoryUrl = rootUrl.appendingPathComponent("Source", isDirectory: true)
    let destinationDirectoryUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceDirectoryUrl,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: destinationDirectoryUrl,
      withIntermediateDirectories: true
    )

    let sourceUrl = sourceDirectoryUrl.appendingPathComponent("Report.txt")
    let sourceData = Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
    try sourceData.write(to: sourceUrl)
    let snapshots = LockedSnapshots()

    let result = FileTransferOperations.copyItems(
      [sourceUrl],
      to: destinationDirectoryUrl,
      progressHandler: { snapshot in
        snapshots.append(snapshot)
      }
    )

    let copiedUrl = try XCTUnwrap(result.copiedUrls.first)
    XCTAssertFalse(result.wasCancelled)
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertEqual(try Data(contentsOf: copiedUrl), sourceData)
    XCTAssertEqual(snapshots.values.last?.completedBytes, Int64(sourceData.count))
    XCTAssertEqual(snapshots.values.last?.completedItemCount, 1)
  }

  func testFileTransferCopiesDirectoryContents() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("Project", isDirectory: true)
    let nestedUrl = sourceUrl.appendingPathComponent("Nested", isDirectory: true)
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedUrl, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: nestedUrl.appendingPathComponent("README.md"))
    try Data(repeating: 0x42, count: 1_024 * 1_024).write(
      to: sourceUrl.appendingPathComponent("Archive.bin")
    )
    let snapshots = LockedSnapshots()

    let result = FileTransferOperations.copyItems(
      [sourceUrl],
      to: destinationUrl,
      progressHandler: { snapshot in
        snapshots.append(snapshot)
      }
    )

    XCTAssertFalse(result.wasCancelled)
    XCTAssertTrue(result.failures.isEmpty)
    let copiedFileUrl =
      destinationUrl
      .appendingPathComponent("Project", isDirectory: true)
      .appendingPathComponent("Nested", isDirectory: true)
      .appendingPathComponent("README.md")
    XCTAssertEqual(try String(contentsOf: copiedFileUrl, encoding: .utf8), "hello")
    let completedByteCounts = snapshots.values.map(\.completedBytes)
    XCTAssertTrue(
      zip(completedByteCounts, completedByteCounts.dropFirst())
        .allSatisfy { $0 <= $1 }
    )
  }

  func testFileTransferGeneratesNonconflictingDestinationName() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("Report.txt")
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: sourceUrl)
    try Data("existing".utf8).write(
      to: destinationUrl.appendingPathComponent("Report.txt")
    )

    let result = FileTransferOperations.copyItems([sourceUrl], to: destinationUrl)

    XCTAssertEqual(result.copiedUrls.first?.lastPathComponent, "Report 2.txt")
    XCTAssertEqual(
      try String(
        contentsOf: destinationUrl.appendingPathComponent("Report.txt"),
        encoding: .utf8
      ),
      "existing"
    )
  }

  func testFileTransferCanBeCancelledBeforeCopying() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("Source.txt")
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)
    try Data("contents".utf8).write(to: sourceUrl)
    let cancellationToken = FileTransferCancellationToken()
    cancellationToken.cancel()

    let result = FileTransferOperations.copyItems(
      [sourceUrl],
      to: destinationUrl,
      cancellationToken: cancellationToken
    )

    XCTAssertTrue(result.wasCancelled)
    XCTAssertTrue(result.copiedUrls.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destinationUrl.appendingPathComponent("Source.txt").path
      )
    )
  }

  func testFileTransferCanBeCancelledWhileCopying() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("LargeFile.bin")
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)
    try Data(repeating: 0x43, count: 8 * 1_024 * 1_024).write(to: sourceUrl)
    let cancellationToken = FileTransferCancellationToken()

    let result = FileTransferOperations.copyItems(
      [sourceUrl],
      to: destinationUrl,
      cancellationToken: cancellationToken,
      progressHandler: { snapshot in
        if snapshot.completedBytes > 0 {
          cancellationToken.cancel()
        }
      }
    )

    XCTAssertTrue(result.wasCancelled)
    XCTAssertTrue(result.copiedUrls.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destinationUrl.appendingPathComponent("LargeFile.bin").path
      )
    )
  }

  func testFileTransferRejectsDestinationInsideSource() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("Source", isDirectory: true)
    let destinationUrl = sourceUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)

    let result = FileTransferOperations.copyItems([sourceUrl], to: destinationUrl)

    XCTAssertFalse(result.wasCancelled)
    XCTAssertTrue(result.copiedUrls.isEmpty)
    XCTAssertEqual(result.failures.count, 1)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directoryUrl = FileManager.default.temporaryDirectory
      .appendingPathComponent("BetterMenuCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryUrl,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryUrl)
    }
    return directoryUrl
  }
}

private final class LockedSnapshots: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [FileTransferProgressSnapshot] = []

  var values: [FileTransferProgressSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return snapshots
  }

  func append(_ snapshot: FileTransferProgressSnapshot) {
    lock.lock()
    snapshots.append(snapshot)
    lock.unlock()
  }
}
