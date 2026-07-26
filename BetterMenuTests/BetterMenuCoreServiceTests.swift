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

  func testDirectoryChangeMonitorRecoversAfterDirectoryRecreation() throws {
    let rootUrl = try makeTemporaryDirectory()
    let monitoredDirectoryUrl = rootUrl.appendingPathComponent("Monitored", isDirectory: true)
    let markerUrl = monitoredDirectoryUrl.appendingPathComponent("icon_cache.plist")
    try FileManager.default.createDirectory(
      at: monitoredDirectoryUrl,
      withIntermediateDirectories: true
    )

    let changeExpectation = expectation(description: "重新创建目录后仍能收到写入事件")
    changeExpectation.assertForOverFulfill = false
    let signal = DirectoryMonitorTestSignal(
      markerUrl: markerUrl,
      expectation: changeExpectation
    )
    let monitor = DirectoryChangeMonitor(
      directoryUrl: monitoredDirectoryUrl,
      queueLabel: "com.zombie.BetterMenuTests.directoryMonitor"
    )
    monitor.start {
      signal.handleChange()
    }
    defer {
      monitor.stop()
    }

    try FileManager.default.removeItem(at: monitoredDirectoryUrl)
    DispatchQueue.global(qos: .utility).async {
      for attempt in 0..<10 where !signal.isComplete {
        do {
          try FileManager.default.createDirectory(
            at: monitoredDirectoryUrl,
            withIntermediateDirectories: true
          )
          try Data("updated-\(attempt)".utf8).write(to: markerUrl, options: .atomic)
        } catch {
          signal.handleFailure(error)
          return
        }
        Thread.sleep(forTimeInterval: 0.2)
      }
    }

    wait(for: [changeExpectation], timeout: 3)
    XCTAssertNil(signal.failureMessage)
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

  /// 统计目录体积需要枚举整棵目录树，这一阶段也必须响应取消，
  /// 否则用户在“正在计算传输大小…”期间点取消会没有任何反应。
  func testFileTransferCancellationDuringByteCountingCopiesNothing() throws {
    let rootUrl = try makeTemporaryDirectory()
    let sourceUrl = rootUrl.appendingPathComponent("Tree", isDirectory: true)
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceUrl, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)
    for index in 0..<600 {
      try Data("x".utf8).write(to: sourceUrl.appendingPathComponent("file-\(index).txt"))
    }

    let cancellationToken = FileTransferCancellationToken()
    cancellationToken.cancel()
    let snapshots = LockedSnapshots()

    let result = FileTransferOperations.copyItems(
      [sourceUrl],
      to: destinationUrl,
      cancellationToken: cancellationToken,
      progressHandler: { snapshot in
        snapshots.append(snapshot)
      }
    )

    XCTAssertTrue(result.wasCancelled)
    XCTAssertTrue(result.copiedUrls.isEmpty)
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertTrue(snapshots.values.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destinationUrl.appendingPathComponent("Tree").path
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

  /// 失败项目也已处理完毕，必须计入进度分子，否则分母含全部项目、
  /// 分子只含成功项，部分失败时进度条会永远停在中途、无法到达 100%。
  func testFileTransferPartialFailureStillCompletesProgress() throws {
    let rootUrl = try makeTemporaryDirectory()
    let destinationUrl = rootUrl.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true)

    // 第一项可以正常复制；第二项是把目录复制进它自己内部，一定失败。
    let copyableUrl = rootUrl.appendingPathComponent("copyable.txt")
    try Data(repeating: 0x41, count: 2048).write(to: copyableUrl)
    let failingSourceUrl = destinationUrl.deletingLastPathComponent()

    let snapshots = LockedSnapshots()
    let result = FileTransferOperations.copyItems(
      [copyableUrl, failingSourceUrl],
      to: destinationUrl,
      progressHandler: { snapshot in
        snapshots.append(snapshot)
      }
    )

    XCTAssertFalse(result.wasCancelled)
    XCTAssertEqual(result.copiedUrls.count, 1)
    XCTAssertEqual(result.failures.count, 1)

    let finalSnapshot = try XCTUnwrap(snapshots.values.last)
    XCTAssertEqual(finalSnapshot.completedItemCount, finalSnapshot.totalItemCount)
    XCTAssertEqual(finalSnapshot.completedItemCount, 2)
    XCTAssertEqual(finalSnapshot.completedBytes, finalSnapshot.totalBytes)
  }

  /// 复制失败提示必须是中文。此前直接返回 `strerror` 的英文文案，
  /// 在全中文界面里会出现 "No space left on device" 之类的混排。
  func testFileTransferErrorMessagesAreLocalized() {
    let localizedErrorNumbers: [Int32] = [
      ENOSPC, EACCES, EPERM, EEXIST, EROFS, EIO, ENOENT, EDQUOT, EFBIG, ENAMETOOLONG, ENOTDIR,
      ENOMEM,
    ]
    for errorNumber in localizedErrorNumbers {
      let message = FileTransferOperations.errorMessage(for: errorNumber)
      XCTAssertFalse(message.isEmpty, "errno \(errorNumber) 缺少提示文案")
      XCTAssertTrue(
        message.contains(where: { $0.unicodeScalars.contains { $0.value > 0x7F } }),
        "errno \(errorNumber) 的提示应为中文，实际为：\(message)"
      )
    }

    // 未单独映射的错误码回落到系统描述，但仍需带上错误码便于排查。
    let fallbackMessage = FileTransferOperations.errorMessage(for: EPIPE)
    XCTAssertTrue(fallbackMessage.contains("\(EPIPE)"))
    XCTAssertTrue(fallbackMessage.hasPrefix("复制失败"))
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

private final class DirectoryMonitorTestSignal: @unchecked Sendable {
  private let markerUrl: URL
  private let expectation: XCTestExpectation
  private let lock = NSLock()
  private var storedFailureMessage: String?
  private var didComplete = false

  init(markerUrl: URL, expectation: XCTestExpectation) {
    self.markerUrl = markerUrl
    self.expectation = expectation
  }

  var failureMessage: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailureMessage
  }

  var isComplete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didComplete
  }

  func handleChange() {
    guard FileManager.default.fileExists(atPath: markerUrl.path) else { return }
    lock.lock()
    guard !didComplete else {
      lock.unlock()
      return
    }
    didComplete = true
    lock.unlock()
    expectation.fulfill()
  }

  func handleFailure(_ error: any Error) {
    lock.lock()
    guard !didComplete else {
      lock.unlock()
      return
    }
    didComplete = true
    storedFailureMessage = error.localizedDescription
    lock.unlock()
    expectation.fulfill()
  }
}
