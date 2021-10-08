import Foundation
import MetalKit

/// A renderable mesh of a chunk section.
public struct ChunkSectionMesh {
  /// The mesh containing transparent and opaque blocks only. Doesn't need sorting.
  public var transparentAndOpaqueMesh: Mesh
  /// The mesh containing translucent blocks. Requires sorting when the player moves (clever stuff is done to minimise sorts in ``WorldRenderer``).
  public var translucentMesh: SortableMesh
  
  public var isEmpty: Bool {
    return transparentAndOpaqueMesh.isEmpty && translucentMesh.isEmpty
  }
  
  /// Create a new chunk section mesh.
  public init(_ uniforms: Uniforms) {
    transparentAndOpaqueMesh = Mesh()
    transparentAndOpaqueMesh.uniforms = uniforms
    translucentMesh = SortableMesh(uniforms: uniforms)
  }
  
  /// Clear the mesh's geometry and invalidate its buffers. Leaves GPU buffers intact for reuse.
  public mutating func clearGeometry() {
    transparentAndOpaqueMesh.clearGeometry()
    translucentMesh.clear()
  }
  
  /// Encode the render commands for this chunk section's opaque and transparent geometry.
  /// - Parameters:
  ///   - commandQueue: Used to create buffers.
  public mutating func renderTransparentAndOpaque(
    encoder: MTLRenderCommandEncoder,
    device: MTLDevice,
    commandQueue: MTLCommandQueue
  ) throws {
    try transparentAndOpaqueMesh.render(into: encoder, with: device, commandQueue: commandQueue)
  }
  
  /// Encode the render commands for this chunk section's translucent geometry.
  /// - Parameters:
  ///   - position: Position to sort the geometry from.
  ///   - sortTranslucent: Whether to sort the geometry or not.
  ///   - commandQueue: Used to create buffers.
  public mutating func renderTranslucent(
    viewedFrom position: SIMD3<Float>,
    sortTranslucent: Bool,
    encoder: MTLRenderCommandEncoder,
    device: MTLDevice,
    commandQueue: MTLCommandQueue
  ) throws {
    try translucentMesh.render(viewedFrom: position, sort: sortTranslucent, encoder: encoder, device: device, commandQueue: commandQueue)
  }
}
