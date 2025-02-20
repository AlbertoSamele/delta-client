import Foundation
import simd

/// An axis aligned bounding box used for efficient collisions and visibility checks.
public struct AxisAlignedBoundingBox: Codable {
  // MARK: Public properties
  
  /// The position of the minimum vertex of the bounding box.
  public var position: SIMD3<Float>
  /// The size of the bounding box.
  public var size: SIMD3<Float>
  
  /// The minimum vertex of the bounding box.
  public var minimum: SIMD3<Float> {
    position
  }
  
  /// The maximum vertex of the bounding box.
  public var maximum: SIMD3<Float> {
    position + size
  }
  
  // MARK: Init
  
  /// Create a new axis aligned bounding box at a position with a given size.
  /// - Parameters:
  ///   - position: The position of the bounding box.
  ///   - size: The size of the bounding box. Must be positive. The absolute value is taken just in case.
  public init(position: SIMD3<Float>, size: SIMD3<Float>) {
    self.position = position
    self.size = abs(size)
  }
  
  /// Create a new axis aligned bounding box with given minimum and maximum vertices.
  /// - Parameters:
  ///   - minimum: The minimum vertex.
  ///   - maximum: The maximum vertex.
  public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
    position = minimum
    size = abs(maximum - minimum)
  }
  
  // MARK: Methods
  
  /// Get an array containing all 8 of this bounding box's vertices.
  /// - Returns: This bounding box's vertices.
  public func getVertices() -> [SIMD3<Float>] {
    let minimum = minimum
    let maximum = maximum
    
    let bfl = minimum
    let bfr = SIMD3<Float>(maximum.x, minimum.y, minimum.z)
    let tfl = SIMD3<Float>(minimum.x, maximum.y, minimum.z)
    let tfr = SIMD3<Float>(maximum.x, maximum.y, minimum.z)
    
    let bbl = SIMD3<Float>(minimum.x, minimum.y, maximum.z)
    let bbr = SIMD3<Float>(maximum.x, minimum.y, maximum.z)
    let tbl = SIMD3<Float>(minimum.x, maximum.y, maximum.z)
    let tbr = maximum
    
    return [bfl, bfr, tfl, tfr, bbl, bbr, tbl, tbr]
  }
  
  /// Get an array containing all 8 of this bounding box's vertices in homogenous form.
  /// - Returns: This bounding box's vertices in homogenous form.
  public func getHomogenousVertices() -> [SIMD4<Float>] {
    let minimum = minimum
    let maximum = maximum
    
    let bfl = SIMD4<Float>(minimum, 1)
    let bfr = SIMD4<Float>(maximum.x, minimum.y, minimum.z, 1)
    let tfl = SIMD4<Float>(minimum.x, maximum.y, minimum.z, 1)
    let tfr = SIMD4<Float>(maximum.x, maximum.y, minimum.z, 1)
    
    let bbl = SIMD4<Float>(minimum.x, minimum.y, maximum.z, 1)
    let bbr = SIMD4<Float>(maximum.x, minimum.y, maximum.z, 1)
    let tbl = SIMD4<Float>(minimum.x, maximum.y, maximum.z, 1)
    let tbr = SIMD4<Float>(maximum, 1)
    
    return [bfl, bfr, tfl, tfr, bbl, bbr, tbl, tbr]
  }
}
