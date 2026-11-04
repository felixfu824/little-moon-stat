import Foundation
import Testing
@testable import Samplers

@Test func productNameStripsModelDetailsAndNULTerminator() {
    #expect(SystemInfo.modelName("MacBook Pro (14-inch, M5 Max)\0") == "MacBook Pro")
    #expect(SystemInfo.modelName("MacBook Air\0") == "MacBook Air")
    #expect(SystemInfo.modelName(nil) == "Mac")
    #expect(SystemInfo.modelName("\0  ") == "Mac")
}

@Test func truncatedProcessNameDropsIncompleteUTF8Suffix() {
    let name = "Traditional Chinese 程序名稱很長的背景工作程序"
    let bytes = Array(name.utf8)
    for count in 0...bytes.count {
        let decoded = LibprocProcessSource.decodeTruncatedName(Array(bytes.prefix(count)))
        #expect(!decoded.contains("\u{fffd}"))
        #expect(name.hasPrefix(decoded))
        #expect(count - decoded.utf8.count <= 3)
    }
    #expect(LibprocProcessSource.decodeTruncatedName(bytes) == name)
    let parsed = PSParsing.parse("42 1024 0:01.00 /Applications/\(name)", atNanos: 1)
    #expect(parsed[42]?.name == name)
}

@Test func libprocPrefersFullExecutableBasename() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "Traditional Chinese 程序名稱很長的背景工作程序"
    let executable = directory.appendingPathComponent(name)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate(); process.waitUntilExit() }
    #expect(LibprocProcessSource().name(for: process.processIdentifier) == name)
    let output = try #require(PSRunner.run(.pid(process.processIdentifier), withName: true))
    #expect(PSParsing.parse(output.output, atNanos: 1)[process.processIdentifier]?.name == name)
}
