import Foundation

public struct PacketDecodingErrorEvent: Event {
  public var packetId: Int
  public var error: String
  
  public init(packetId: Int, error: String) {
    self.packetId = packetId
    self.error = error
  }
}
