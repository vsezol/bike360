import Testing

@testable import Pipeline

@Test func versionIsSet() {
  #expect(Pipeline.version == "0.0.1")
}
