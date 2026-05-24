import Foundation
import Metal

// Shared Metal resources: device, command queue, and the package's compiled
// shader library. Module instances should reuse a single context.
//
// SwiftPM under Command Line Tools (no full Xcode) only copies .metal files
// into the resource bundle without compiling them to .metallib. We load the
// .metal source as a text resource and compile it at runtime — slower on
// first use but portable across CLT and Xcode toolchains.
public final class MetalContext: @unchecked Sendable {
  public let device: MTLDevice
  public let commandQueue: MTLCommandQueue
  public let library: MTLLibrary

  public init() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw MetalContextError.noDevice
    }
    guard let queue = device.makeCommandQueue() else {
      throw MetalContextError.noCommandQueue
    }
    self.device = device
    self.commandQueue = queue

    let source = try Self.loadShaderSource(name: "FisheyeUndistorter")
    do {
      self.library = try device.makeLibrary(source: source, options: nil)
    } catch {
      throw MetalContextError.libraryLoadFailed(underlying: error)
    }
  }

  private static func loadShaderSource(name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "metal") else {
      throw MetalContextError.shaderSourceMissing(name: name)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  public func makeComputePipelineState(functionName: String) throws -> MTLComputePipelineState {
    guard let function = library.makeFunction(name: functionName) else {
      throw MetalContextError.functionNotFound(name: functionName)
    }
    return try device.makeComputePipelineState(function: function)
  }
}

public enum MetalContextError: Error, CustomStringConvertible {
  case noDevice
  case noCommandQueue
  case shaderSourceMissing(name: String)
  case libraryLoadFailed(underlying: any Error)
  case functionNotFound(name: String)

  public var description: String {
    switch self {
    case .noDevice: return "MTLCreateSystemDefaultDevice returned nil"
    case .noCommandQueue: return "MTLDevice.makeCommandQueue() returned nil"
    case .shaderSourceMissing(let name): return "Shader source not found in bundle: \(name).metal"
    case .libraryLoadFailed(let err): return "Failed to compile Metal library: \(err)"
    case .functionNotFound(let name): return "Metal function not found in library: \(name)"
    }
  }
}
