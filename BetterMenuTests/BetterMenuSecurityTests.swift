import Cocoa
import XCTest

final class BetterMenuSecurityTests: XCTestCase {
  func testSecureRequestRoundTripConsumesFileOnce() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.runAction(
      actionId: "terminal",
      path: "/Users/test/Project",
      createdAt: 100
    )

    try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)
    let consumedRequest = try BetterMenuSecureRequestStore.consume(
      requestId: request.id,
      directoryUrl: directoryUrl,
      now: 101
    )

    XCTAssertEqual(consumedRequest, request)
    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.consume(
        requestId: request.id,
        directoryUrl: directoryUrl,
        now: 101
      )
    )
  }

  func testSecureRequestRejectsExpiredPayload() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.runAction(
      actionId: "terminal",
      path: "/Users/test/Project",
      createdAt: 100
    )

    try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)

    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.consume(
        requestId: request.id,
        directoryUrl: directoryUrl,
        now: 131
      )
    )
  }

  func testSecureRequestRejectsBroadFilePermissions() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.runAction(
      actionId: "terminal",
      path: "/Users/test/Project"
    )
    try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)

    let requestUrl =
      directoryUrl
      .appendingPathComponent(request.id.uuidString.lowercased())
      .appendingPathExtension("plist")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: requestUrl.path
    )

    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.consume(
        requestId: request.id,
        directoryUrl: directoryUrl
      )
    )
  }

  func testSecureRequestRejectsBroadDirectoryPermissions() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.runAction(
      actionId: "terminal",
      path: "/Users/test/Project"
    )
    try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: directoryUrl.path
    )

    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.consume(
        requestId: request.id,
        directoryUrl: directoryUrl
      )
    )
  }

  func testLaunchUrlContainsOnlyOpaqueRequestIdentifier() throws {
    let requestId = UUID()
    let url = try BetterMenuSecureRequestStore.launchUrl(for: requestId)
    let parsedRequestId = try BetterMenuSecureRequestStore.requestId(from: url)

    XCTAssertEqual(parsedRequestId, requestId)
    XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)

    let legacyUrl = try XCTUnwrap(
      URL(string: "bettermenu://run-action?id=terminal&path=/Users/test/Secret"))
    XCTAssertThrowsError(try BetterMenuSecureRequestStore.requestId(from: legacyUrl))

    let urlWithExtraParameter = try XCTUnwrap(
      URL(string: "\(url.absoluteString)&path=/Users/test/Secret"))
    XCTAssertThrowsError(try BetterMenuSecureRequestStore.requestId(from: urlWithExtraParameter))

    let urlWithExtraPath = try XCTUnwrap(
      URL(string: "bettermenu://request/extra?id=\(requestId.uuidString)"))
    XCTAssertThrowsError(try BetterMenuSecureRequestStore.requestId(from: urlWithExtraPath))
  }

  func testSecureRequestRejectsNonStandardPath() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.runAction(
      actionId: "terminal",
      path: "/Users/test/../Secret"
    )

    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)
    )
  }

  func testCopyRequestRequiresDestination() throws {
    let directoryUrl = try makeTemporaryDirectory()
    let request = BetterMenuSecureRequest.fileTransfer(
      sourcePaths: ["/Users/test/Document.txt"],
      mode: .copy,
      destinationPath: nil
    )

    XCTAssertThrowsError(
      try BetterMenuSecureRequestStore.submit(request, directoryUrl: directoryUrl)
    )
  }

  func testAppleScriptPathLiteralRoundTripsSpecialCharacters() throws {
    let path = "/tmp/quote\" slash\\ single' ampersand&\nline\rreturn\ttab"
    let literal = AppleScriptPathArgument.sourceLiteral(for: path)
    let script = try XCTUnwrap(NSAppleScript(source: "return \(literal)"))
    var errorInfo: NSDictionary?

    let result = script.executeAndReturnError(&errorInfo)

    XCTAssertNil(errorInfo)
    XCTAssertEqual(result.stringValue, path)
  }

  func testAppleScriptPathLiteralDoesNotExecuteInjectedSource() throws {
    let path = "/tmp/\" & do shell script \"exit 99\" & \""
    let literal = AppleScriptPathArgument.sourceLiteral(for: path)
    let script = try XCTUnwrap(NSAppleScript(source: "return \(literal)"))
    var errorInfo: NSDictionary?

    let result = script.executeAndReturnError(&errorInfo)

    XCTAssertNil(errorInfo)
    XCTAssertEqual(result.stringValue, path)
  }

  func testRequiredActionsMigrationPreservesExistingOrderAndState() {
    let existingActions = [
      FinderAction(id: "copyPath", title: "复制当前路径", iconName: "doc.on.doc", isEnabled: false),
      FinderAction(id: "terminal", title: "在终端中打开", iconName: "terminal", isEnabled: true),
    ]

    let migratedActions = actionsAddingMissingRequiredActions(existingActions)

    XCTAssertEqual(migratedActions.map(\.id), ["copyPath", "sendFile", "terminal"])
    XCTAssertEqual(migratedActions.first(where: { $0.id == "copyPath" })?.isEnabled, false)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directoryUrl = FileManager.default.temporaryDirectory
      .appendingPathComponent("BetterMenuTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryUrl)
    }
    return directoryUrl
  }
}
