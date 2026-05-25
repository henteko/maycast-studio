import Testing
import Foundation

@Test
func harnessFindsBinary() {
    let harness = E2EHarness()
    #expect(FileManager.default.fileExists(atPath: harness.maycastBinary.path),
            "maycast binary should exist at \(harness.maycastBinary.path). Run `swift build` first.")
}

@Test
func cliPrintsVersion() throws {
    let harness = E2EHarness()
    let result = try harness.run(["--version"])
    #expect(result.succeeded, "stderr: \(result.stderr)")
    // Assert a semver-shaped string rather than a literal, so routine version
    // bumps in MaycastVersion don't break this test.
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
        trimmed.wholeMatch(of: /\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?/) != nil,
        "expected a semver --version, got '\(trimmed)'"
    )
}
