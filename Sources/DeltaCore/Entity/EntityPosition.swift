import Foundation
import simd

/// The position of an entity. All components are doubles.
public struct EntityPosition {
  public var x: Double
  public var y: Double
  public var z: Double
  
  /// The position of the chunk this position is in.
  public var chunk: ChunkPosition {
    let chunkX = Int((x / 16).rounded(.down))
    let chunkZ = Int((z / 16).rounded(.down))
    
    return ChunkPosition(chunkX: chunkX, chunkZ: chunkZ)
  }
  
  /// The position of the chunk section this position is in.
  public var chunkSection: ChunkSectionPosition {
    let sectionX = Int((x / 16).rounded(.down))
    let sectionY = Int((y / 16).rounded(.down))
    let sectionZ = Int((z / 16).rounded(.down))
    
    return ChunkSectionPosition(sectionX: sectionX, sectionY: sectionY, sectionZ: sectionZ)
  }
  
  /// The float vector representing this position.
  public var vector: SIMD3<Float> {
    return SIMD3<Float>(
      Float(x),
      Float(y),
      Float(z)
    )
  }
}
