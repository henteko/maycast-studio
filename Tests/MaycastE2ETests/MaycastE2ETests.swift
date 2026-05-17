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
    #expect(result.stdout.contains("0.0.1"))
}
