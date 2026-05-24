public protocol PipelineModule<Input, Output>: Sendable {
  associatedtype Input: Sendable
  associatedtype Output: Sendable

  func process(_ input: Input) async throws -> Output
}
