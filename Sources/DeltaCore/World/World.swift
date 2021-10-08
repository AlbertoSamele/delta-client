import Foundation
import simd

/// Holds all of the world data.
///
/// Includes chunks, lighting and some other metadata.
public class World {
  /// The name of this world
  public var name: Identifier
  /// The dimension data for this world
  public var dimension: Identifier
  /// The hashed seed of this world
  public var hashedSeed: Int
  /// Whether this world is a debug world or not
  public var isDebug: Bool
  /// Whether this world is superflat or not.
  public var isFlat: Bool
  
  /// The world's chunks.
  public var chunks: [ChunkPosition: Chunk] = [:]
  /// The number of currently loaded chunks in this world for this client.
  public var chunkCount: Int {
    return chunks.count
  }
  
  /// The world's age.
  public var age: Int = 0
  /// The time of day.
  public var timeOfDay: Int = 0
  /// Whether this world is still downloading terrain.
  public var downloadingTerrain = true
  
  /// Lighting data that arrived before its respective chunk or was sent for a non-existent chunk.
  private var chunklessLightingData: [ChunkPosition: ChunkLightingUpdateData] = [:]
  
  private var lightingEngine = LightingEngine()
  
  private var eventBus: EventBus
  
  /// Used to do thread safe accesses.
  private var accessQueue = DispatchQueue(label: "dev.stackotter.delta-client.World.accessQueue", attributes: .concurrent)
  private var accessQueueKey = DispatchSpecificKey<Void>()
  
  // MARK: Init
  
  /// Creates a new `World` from `World.Info`.
  public init(from descriptor: WorldDescriptor, eventBus: EventBus) {
    name = descriptor.worldName
    dimension = descriptor.dimension
    hashedSeed = descriptor.hashedSeed
    isFlat = descriptor.isFlat
    isDebug = descriptor.isDebug
    self.eventBus = eventBus
    
    accessQueue.setSpecific(key: accessQueueKey, value: ())
  }
  
  // MARK: Thread safety
  
  /// Run a task that should block the access queue (mostly just if it's a write operation).
  ///
  /// Do not call from within a read task.
  ///
  /// - Parameter task: Task to run.
  private func writeTask(_ task: () -> Void) {
    accessQueue.sync(flags: [.barrier]) {
      task()
    }
  }
  
  /// Run a task that does not need exclusive access.
  /// - Returns: Task to run. Should not call a write task (will crash fatally).
  private func readTask<T>(_ task: () -> T) -> T {
    if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
      return task()
    } else {
      return accessQueue.sync {
        return task()
      }
    }
  }
  
  // MARK: Update
  
  /// Updates the world's properties to match the supplied descriptor.
  public func update(with descriptor: WorldDescriptor) {
    writeTask {
      name = descriptor.worldName
      dimension = descriptor.dimension
      hashedSeed = descriptor.hashedSeed
      isFlat = descriptor.isFlat
      isDebug = descriptor.isDebug
    }
  }
  
  /// Updates the world's time to match a `TimeUpdatePacket`.
  public func updateTime(with packet: TimeUpdatePacket) {
    writeTask {
      age = packet.worldAge
      timeOfDay = packet.timeOfDay
    }
  }
  
  // MARK: Blocks
  
  /// Sets the block at the specified position to the specified block state.
  ///
  /// This will trigger lighting to be updated. Emits the `World.Event.SetBlock` event.
  public func setBlockStateId(at position: Position, to state: UInt16) {
    writeTask {
      if let chunk = chunk(at: position.chunk) {
        chunk.setBlockStateId(at: position.relativeToChunk, to: state)
        lightingEngine.updateLighting(at: position, in: self)
        
        let event = Event.SetBlock(
          position: position,
          newState: state)
        eventBus.dispatch(event)
      } else {
        log.warning("Cannot set block in non-existent chunk, chunkPosition=\(position.chunk)")
      }
    }
  }
  
  
  /// Get the block state id of a block.
  /// - Parameter position: A block position in world coordinates.
  /// - Returns: A block state id. If `position` is in a chunk that isn't loaded, air (0) is returned.
  public func getBlockStateId(at position: Position) -> UInt16 {
    readTask {
      if let chunk = chunk(at: position.chunk), Self.isValidBlockPosition(position) {
        return chunk.getBlockStateId(at: position.relativeToChunk)
      } else {
        return 0 // TODO: do not just default to air, maybe void air instead?
      }
    }
  }
  
  /// Returns information about the type of block at the specified position.
  public func getBlock(at position: Position) -> Block {
    readTask {
      return Registry.blockRegistry.block(withId: Int(getBlockStateId(at: position))) ?? Block.missing
    }
  }
  
  /// Get information about the state of a block.
  /// - Parameter position: A block position in world coordinates.
  /// - Returns: Information about a block's state. If the block is in a chunk that isn't loaded,
  ///   air (0) is returned. If the block state is invalid for whatever reason, ``BlockState.missing`` is returned.
  public func getBlockState(at position: Position) -> BlockState {
    readTask {
      return Registry.blockRegistry.blockState(withId: Int(getBlockStateId(at: position))) ?? BlockState.missing
    }
  }
  
  // MARK: Lighting
  
  
  /// Sets the block light level of a block. Does not propagate the change and does not verify the level is valid.
  ///
  /// Does not emit an event. If `position` is in a chunk that isn't loaded or is above y=255 or below y=0, nothing happens.
  ///
  /// - Parameters:
  ///   - position: A block position relative to the world.
  ///   - level: The new light level. Should be from 0 to 15 inclusive. Not validated.
  public func setBlockLightLevel(at position: Position, to level: Int) {
    writeTask {
      if let chunk = self.chunk(at: position.chunk) {
        chunk.lighting.setBlockLightLevel(at: position.relativeToChunk, to: level)
      }
    }
  }
  
  // TODO: Finish fixing documentation for World
  
  /// Returns the block light level for the given block.
  public func getBlockLightLevel(at position: Position) -> Int {
    readTask {
      if let chunk = self.chunk(at: position.chunk) {
        return chunk.lighting.getBlockLightLevel(at: position.relativeToChunk)
      } else {
        return LightLevel.defaultBlockLightLevel
      }
    }
  }
  
  /// Sets the sky light level for the given block. Does not propagate the change and does not verify the level is valid.
  ///
  /// Does not emit an event. If `position` is in a chunk that isn't loaded or is above y=255 or below y=0, nothing happens.
  public func setSkyLightLevel(at position: Position, to level: Int) {
    writeTask {
      if let chunk = self.chunk(at: position.chunk) {
        chunk.lighting.setSkyLightLevel(at: position.relativeToChunk, to: level)
      }
    }
  }
  
  /// Returns the sky light level for the given block.
  public func getSkyLightLevel(at position: Position) -> Int {
    readTask {
      if let chunk = self.chunk(at: position.chunk) {
        return chunk.lighting.getSkyLightLevel(at: position.relativeToChunk)
      } else {
        return LightLevel.defaultSkyLightLevel
      }
    }
  }
  
  // MARK: Chunks
  
  /// Get the chunk at the specified position if present.
  public func chunk(at chunkPosition: ChunkPosition) -> Chunk? {
    readTask {
      return chunks[chunkPosition]
    }
  }
  
  /// Get the chunks neighbouring the specified chunk with their respective directions.
  public func neighbours(ofChunkAt chunkPosition: ChunkPosition) -> [CardinalDirection: Chunk] {
    readTask {
      let neighbourPositions = chunkPosition.allNeighbours
      var neighbourChunks: [CardinalDirection: Chunk] = [:]
      for (direction, neighbourPosition) in neighbourPositions {
        if let neighbour = chunk(at: neighbourPosition) {
          neighbourChunks[direction] = neighbour
        }
      }
      return neighbourChunks
    }
  }
  
  /// Add a chunk to the world.
  ///
  /// Also emits the `World.Event.AddChunk` event.
  public func addChunk(_ chunk: Chunk, at position: ChunkPosition) {
    writeTask {
      if let lightingData = chunklessLightingData.removeValue(forKey: position) {
        chunk.lighting.update(with: lightingData)
      }
      chunks[position] = chunk
      
      let event = Event.AddChunk(position: position, chunk: chunk)
      eventBus.dispatch(event)
    }
  }
  
  /// Update a chunk with data received from the server.
  /// - Parameters:
  ///   - position: Position of the chunk.
  ///   - packet: New chunk data received from the server.
  public func updateChunk(at position: ChunkPosition, with packet: ChunkDataPacket) {
    writeTask {
      if let existingChunk = chunk(at: position) {
        existingChunk.update(with: packet)
        eventBus.dispatch(World.Event.UpdateChunk(position: position))
      } else {
        log.warning("Attempted to update chunk that doesn't exist (position=\(position)")
      }
    }
  }
  
  /// Update a chunk's lighting with lighting data received from the server.
  ///
  /// Emits the `World.Event.UpdateChunkLighting` event if the chunk exists. Otherwise, the lighting data
  /// is stored temporarily in `chunklessLightingData` until the chunk arrives.
  public func updateChunkLighting(at position: ChunkPosition, with data: ChunkLightingUpdateData) {
    writeTask {
      if let chunk = chunk(at: position) {
        chunk.lighting.update(with: data)
        
        let event = Event.UpdateChunkLighting(position: position, data: data)
        eventBus.dispatch(event)
      } else {
        // Most likely the chunk just hasn't unpacked yet so wait for that
        chunklessLightingData[position] = data // TODO: concurrent access fatal error happens here, fix it
      }
    }
  }
  
  /// Removes the chunk at the specified position if present.
  ///
  /// Emits a `World.Event.RemoveChunk` event.
  public func removeChunk(at position: ChunkPosition) {
    writeTask {
      let event = Event.RemoveChunk(position: position)
      eventBus.dispatch(event)
      self.chunks.removeValue(forKey: position)
    }
  }
  
  // MARK: Helper
  
  public func chunkExists(at position: ChunkPosition) -> Bool {
    readTask {
      // Do you think that's enough selfs?
      return self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.self.chunks[position] != nil
    }
  }
  
  /// Returns whether a chunk is present and has its lighting or not.
  public func chunkComplete(at position: ChunkPosition) -> Bool {
    readTask {
      if let chunk = chunk(at: position) {
        return chunk.lighting.isPopulated
      }
      return false
    }
  }
  
  /// Returns whether the given position is in a loaded chunk or not.
  public func isPositionLoaded(_ position: Position) -> Bool {
    readTask {
      return chunkComplete(at: position.chunk)
    }
  }
  
  /// Returns whether a block position is below the world height limit and above 0.
  public static func isValidBlockPosition(_ position: Position) -> Bool {
    return position.y < Chunk.height && position.y >= 0
  }
}
