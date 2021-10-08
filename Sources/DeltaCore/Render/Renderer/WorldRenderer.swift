import Foundation
import MetalKit
import simd

/// A renderer that renders a `World`
class WorldRenderer {
  var world: World
  var client: Client
  
  // MARK: Rendering pipeline
  
  /// Render pipeline used for rendering blocks.
  var renderPipelineState: MTLRenderPipelineState
  /// Depth stencil.
  var depthState: MTLDepthStencilState
  
  var camera = Camera()
  
  // MARK: Resources and textures
  var resources: ResourcePack.Resources
  var blockArrayTexture: MTLTexture
  var blockTexturePaletteAnimationState: TexturePaletteAnimationState
  
  // MARK: Meshes
  
  var chunkMeshes: [ChunkPosition: [Int: ChunkSectionMesh]] = [:]
  
  let maximumPreparingMeshes = 4
  var preparingMeshesCounter = Counter(0)
  var meshPreparationQueue = DispatchQueue(label: "dev.stackotter.delta-client.WorldRenderer.meshPreparationQueue", attributes: .concurrent)
  var meshesAccessQueue = DispatchQueue(label: "dev.stackotter.delta-client.WorldRenderer.meshAccessQueue")
  var sectionsToPrepare: [ChunkSectionPosition] = []
  
  // MARK: Uniforms
  
  // TODO: make generic triple buffer type
  var worldUniformBuffers: [MTLBuffer] = []
  var numWorldUniformBuffers = 3
  var worldUniformBufferIndex = 0
  
  // MARK: Init
  
  init(device: MTLDevice, world: World, client: Client, resources: ResourcePack.Resources, commandQueue: MTLCommandQueue) throws {
    // Load shaders
    log.info("Loading shaders")
    guard let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/DeltaClient_DeltaCore.bundle")) else {
      throw RenderError.failedToGetBundle
    }
    guard let libraryURL = bundle.url(forResource: "default", withExtension: "metallib") else {
      throw RenderError.failedToLocateMetallib
    }
    let library: MTLLibrary
    do {
      library = try device.makeLibrary(URL: libraryURL)
    } catch {
      throw RenderError.failedToCreateMetallib(error)
    }

    guard
      let vertex = library.makeFunction(name: "chunkVertexShader"),
      let fragment = library.makeFunction(name: "chunkFragmentShader")
    else {
      log.critical("Failed to load chunk shaders")
      throw RenderError.failedToLoadShaders
    }
    
    self.world = world
    self.client = client
    self.resources = resources
    
    let blockTexturePalette = resources.blockTexturePalette
    blockTexturePaletteAnimationState = TexturePaletteAnimationState(for: blockTexturePalette)
    blockArrayTexture = try Self.createArrayTexture(palette: blockTexturePalette, animationState: blockTexturePaletteAnimationState, device: device, commandQueue: commandQueue)
    renderPipelineState = try Self.createRenderPipelineState(vertex: vertex, fragment: fragment, device: device)
    depthState = try Self.createDepthState(device: device)
    worldUniformBuffers = try Self.createWorldUniformBuffers(device: device, count: numWorldUniformBuffers)
    
    client.eventBus.registerHandler(handle)
    
    // Prepare meshes for the chunks already in the world. It's async, don't worry.
    for (position, _) in world.chunks {
      for sectionPosition in position.sections {
        prepareMeshAsync(forSectionAt: sectionPosition)
      }
    }
  }
  
  // MARK: Meshes
  
  
  /// A thread-safe counter
  public struct Counter {
    private var queue = DispatchQueue(label: "dev.stackotter.delta-client.Counter", attributes: .concurrent)
    
    private var _value: Int
    
    public var value: Int {
      get {
        return queue.sync {
          return self._value
        }
      }
      set(newValue) {
        queue.sync(flags: [.barrier]) {
          self._value = newValue
        }
      }
    }
    
    public init(_ initialValue: Int) {
      _value = initialValue
    }
    
    public mutating func increment() {
      value += 1
    }
    
    public mutating func decrement() {
      value -= 1
    }
  }
  
  /// Prepare a mesh for a chunk section and then add it to be rendered (unless it's empty).
  ///
  /// If the mesh can't be prepared immediately (i.e. there are already multiple meshes preparing), then the section is
  /// added to `sectionsToPrepare` and is prepared at the next opportunity. Each time a mesh finishes preparing,
  /// `sectionsToPrepare` is sorted by distance from player (and also whether the sections are in the frustum), and the next
  /// one starts preparing. Reuses the resources of the existing mesh at that position if possible.
  ///
  /// - Parameters:
  ///   - sectionPosition: Position of chunk section to create mesh for.
  func prepareMeshAsync(forSectionAt sectionPosition: ChunkSectionPosition) {
    // TODO: use world snapshots
    meshPreparationQueue.async {
      // Limits the number of meshes preparing at once for performance reasons (too many at once affects fps)
      var existingMesh: ChunkSectionMesh? = nil
      var delayed = false
      self.meshesAccessQueue.sync {
        guard self.preparingMeshesCounter.value < self.maximumPreparingMeshes else {
          delayed = true
          self.sectionsToPrepare.append(sectionPosition)
          return
        }
        
        self.preparingMeshesCounter.increment()
        existingMesh = self.chunkMeshes[sectionPosition.chunk]?[sectionPosition.sectionY]
      }
      
      if delayed {
        return
      }
      
      // Get chunks required
      let chunkPosition = sectionPosition.chunk
      let neighbourChunks = self.world.neighbours(ofChunkAt: chunkPosition)
      guard let chunk = self.world.chunk(at: sectionPosition.chunk) else {
        log.warning("Failed to get chunks to prepare mesh for chunk section at \(sectionPosition)")
        return
      }
      
      // Build mesh
      let builder = ChunkSectionMeshBuilder(
        forSectionAt: sectionPosition,
        in: chunk,
        withNeighbours: neighbourChunks,
        resources: self.resources)
      if let mesh = builder.build(reusing: existingMesh) {
        self.addMesh(at: sectionPosition, mesh)
      }
      
      self.preparingMeshesCounter.decrement()
      
      // Prepare next mesh if there are any queued
      self.meshesAccessQueue.async {
        if !self.sectionsToPrepare.isEmpty {
          self.sectionsToPrepare = self.sortMeshPositions(camera: self.camera, meshPositions: self.sectionsToPrepare, visibleOnly: false)
          let nextMeshPosition = self.sectionsToPrepare.removeFirst()
          self.prepareMeshAsync(forSectionAt: nextMeshPosition)
        }
      }
    }
  }
  
  /// Add a mesh to the renderer. Replaces any existing mesh at that position.
  /// - Parameters:
  ///   - position: Position mesh should be inserted at.
  ///   - mesh: Chunk section mesh to add.
  func addMesh(at position: ChunkSectionPosition, _ mesh: ChunkSectionMesh) {
    let chunkPosition = position.chunk
    self.meshesAccessQueue.sync {
      if var sectionMeshes = chunkMeshes[chunkPosition] {
        sectionMeshes[position.sectionY] = mesh
        chunkMeshes[chunkPosition] = sectionMeshes
      } else {
        chunkMeshes[chunkPosition] = [position.sectionY: mesh]
      }
    }
  }
  
  /// They are sorted by distance from the player and then the visible ones are put first.
  ///
  /// The visibility check is only approximate. All visible meshes will be included, but some false
  /// positives may occur in certain situations.
  ///
  /// - Parameter camera: The camera that is being rendered from. Used to determine which sections are in view from the camera.
  /// - Parameter meshPositions: The positions of all meshes that should be sorted and filtered to find visible positions.
  /// - Parameter visibleOnly: If `true`, only visible mesh positions are returned.
  /// - Returns: The sorted mesh positions.
  func sortMeshPositions(camera: Camera, meshPositions: [ChunkSectionPosition], visibleOnly: Bool = false) -> [ChunkSectionPosition] {
    let playerPosition = client.server?.player.position ?? EntityPosition(x: 0, y: 0, z: 0)
    
    // Sort meshes by distance from player
    let offset = SIMD3<Float>(Float(Chunk.width), Float(Chunk.height), Float(Chunk.depth)) / 2
    let playerPositionVector = playerPosition.vector
    var sortedMeshPositions = meshPositions.sorted {
      // Get center position of each chunk section
      let point1 = SIMD3<Float>(
        Float($0.sectionX * Chunk.width),
        Float($0.sectionY * Chunk.height),
        Float($0.sectionZ * Chunk.depth)) + offset
      let point2 = SIMD3<Float>(
        Float($1.sectionX * Chunk.width),
        Float($1.sectionY * Chunk.height),
        Float($1.sectionZ * Chunk.depth)) + offset
      
      // Get distances from camera
      let distance1 = simd_distance_squared(playerPositionVector, point1)
      let distance2 = simd_distance_squared(playerPositionVector, point2)
      return distance2 < distance1
    }
    
    // Get visible meshes
    let playerChunkPosition = playerPosition.chunk
    let visibleMeshPositions = sortedMeshPositions.filter { position in
      let distance = max(
        abs(playerChunkPosition.chunkX - position.sectionX),
        abs(playerChunkPosition.chunkZ - position.sectionZ))
      return distance < client.renderDistance && camera.isChunkSectionVisible(at: position)
    }
    
    if visibleOnly {
      return visibleMeshPositions
    }
    
    // Put visible mesh positions first
    let visibleMeshPositionsSet = Set(visibleMeshPositions)
    sortedMeshPositions = sortedMeshPositions.sorted {
      !(!visibleMeshPositionsSet.contains($0) && visibleMeshPositionsSet.contains($1))
    }
    
    return sortedMeshPositions
  }
  
  // MARK: Rendering
  
  /// Renders the currently visible chunks.
  /// - Parameters:
  ///   - device: Graphics device to use.
  ///   - view: View that is getting rendered in.
  ///   - commandBuffer: Command buffer to use for rendering geometry.
  ///   - camera: Camera to render from.
  ///   - commandQueue: Command queue to use. Used for blit operations such as updating animated textures.
  func render(
    device: MTLDevice,
    view: MTKView,
    commandBuffer: MTLCommandBuffer,
    camera: Camera,
    commandQueue: MTLCommandQueue
  ) {
    self.camera = camera
    
    // Update animated textures
    let updatedTextures = blockTexturePaletteAnimationState.update(tick: client.getClientTick())
    stopwatch.startMeasurement("update texture")
    resources.blockTexturePalette.updateArrayTexture(
      arrayTexture: blockArrayTexture,
      device: device,
      animationState: blockTexturePaletteAnimationState,
      updatedTextures: updatedTextures,
      commandQueue: commandQueue)
    stopwatch.stopMeasurement("update texture")
    
    let uniformsBuffer = getUniformsBuffer(for: camera)
    
    stopwatch.startMeasurement("get visible chunks")
    // Get the positions of all meshes
    var meshPositions: [ChunkSectionPosition] = []
    for (chunkPosition, sectionMeshes) in chunkMeshes {
      for (sectionY, _) in sectionMeshes {
        meshPositions.append(ChunkSectionPosition(chunkPosition, sectionY: sectionY))
      }
    }
    
    // Sort all mesh positions and only include visible ones
    let visibleMeshes = sortMeshPositions(camera: camera, meshPositions: meshPositions, visibleOnly: true)
    
    sectionsToPrepare = sortMeshPositions(camera: camera, meshPositions: sectionsToPrepare, visibleOnly: false)
    stopwatch.stopMeasurement("get visible chunks")
    
    // Get the render pass descriptor as late as possible
    guard
      let renderPassDescriptor = view.currentRenderPassDescriptor,
      let drawableTexture = renderPassDescriptor.colorAttachments[0].texture
    else {
      log.warning("Failed to get current render pass descriptor and drawable texture")
      return
    }
    
    // Create render descriptor
    let renderDescriptor = MTLRenderPassDescriptor()
    renderDescriptor.colorAttachments[0].texture = drawableTexture
    renderDescriptor.colorAttachments[0].loadAction = .clear
    renderDescriptor.colorAttachments[0].storeAction = .store
    renderDescriptor.depthAttachment = renderPassDescriptor.depthAttachment
    renderDescriptor.depthAttachment.loadAction = .load
    
    // Create encoder
    let encoder: MTLRenderCommandEncoder
    do {
      encoder = try Self.createRenderEncoder(
        depthState: depthState,
        commandBuffer: commandBuffer,
        renderPassDescriptor: renderPassDescriptor,
        pipelineState: renderPipelineState)
    } catch {
      log.warning("Failed to create render command encoder; \(error)")
      return
    }
    
    // Encode render pass
    stopwatch.startMeasurement("encode")
    encoder.setFragmentTexture(blockArrayTexture, index: 0)
    encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
    
    do {
      // Draw transparent and opaque geometry first
      for sectionPosition in visibleMeshes {
        try chunkMeshes[sectionPosition.chunk]?[sectionPosition.sectionY]?.renderTransparentAndOpaque(encoder: encoder, device: device, commandQueue: commandQueue)
      }
      
      // Draw translucent geometry last
      for sectionPosition in visibleMeshes {
        try chunkMeshes[sectionPosition.chunk]?[sectionPosition.sectionY]?.renderTranslucent(viewedFrom: camera.position, sortTranslucent: true, encoder: encoder, device: device, commandQueue: commandQueue)
      }
    } catch {
      log.error("Failed to render chunk meshes; \(error)")
    }
    
    encoder.endEncoding()
    stopwatch.stopMeasurement("encode")
  }
  
  // MARK: Event handling
  
  /// Handle world events and update meshes as necessary.
  func handle(_ event: Event) {
    // TODO: group multiblock updates into one event so only one mesh update.
    
    var sectionsToUpdate: Set<ChunkSectionPosition> = []
    
    switch event {
      case let event as World.Event.AddChunk:
        let affectedChunks = event.position.andNeighbours
        for chunkPosition in affectedChunks where canRenderChunk(at: chunkPosition) && chunkMeshes[chunkPosition] == nil {
          sectionsToUpdate.formUnion(chunkPosition.sections)
        }
      case let event as World.Event.RemoveChunk:
        for chunkPosition in event.position.andNeighbours {
          chunkMeshes[chunkPosition] = nil
        }
      case let chunkLightingUpdate as World.Event.UpdateChunkLighting:
        // TODO: only update meshes affected by the lighting update
        let affectedChunks = chunkLightingUpdate.position.andNeighbours
        for chunkPosition in affectedChunks where canRenderChunk(at: chunkPosition) {
          sectionsToUpdate.formUnion(chunkPosition.sections)
        }
      case let blockUpdate as World.Event.SetBlock:
        let affectedSections = sectionsAffected(by: blockUpdate)
        sectionsToUpdate.formUnion(affectedSections)
      case let chunkUpdate as World.Event.UpdateChunk:
        // TODO: only remesh updated chunk sections
        for sectionIndex in 0..<16 {
          let sectionPosition = ChunkSectionPosition(chunkUpdate.position, sectionY: sectionIndex)
          let neighbours = sectionsNeighbouring(sectionAt: sectionPosition)
          sectionsToUpdate.formUnion(neighbours)
        }
      default:
        break
    }
    
    // Update all necessary section meshes
    for sectionPosition in sectionsToUpdate {
      self.prepareMeshAsync(forSectionAt: sectionPosition)
    }
  }
  
  // MARK: Helper
  
  /// Creates a render encoder.
  private static func createRenderEncoder(
    depthState: MTLDepthStencilState,
    commandBuffer: MTLCommandBuffer,
    renderPassDescriptor: MTLRenderPassDescriptor,
    pipelineState: MTLRenderPipelineState
  ) throws -> MTLRenderCommandEncoder {
    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      throw RenderError.failedToCreateRenderEncoder(pipelineState.label ?? "pipeline")
    }
    
    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setDepthStencilState(depthState)
    renderEncoder.setFrontFacing(.clockwise)
    renderEncoder.setCullMode(.back)
    
    return renderEncoder
  }
  
  /// Returns whether a chunk is ready to be rendered or not.
  ///
  /// To be renderable, a chunk must be complete and so must its neighours.
  private func canRenderChunk(at position: ChunkPosition) -> Bool {
    let chunkPositions = position.andNeighbours
    for chunkPosition in chunkPositions {
      if !world.chunkComplete(at: chunkPosition) {
        return false
      }
    }
    return true
  }
  
  /// Returns the sections that require re-meshing after the specified block update.
  private func sectionsAffected(by blockUpdate: World.Event.SetBlock) -> [ChunkSectionPosition] {
    var affectedSections: [ChunkSectionPosition] = [blockUpdate.position.chunkSection]
    
    let updateRelativeToChunk = blockUpdate.position.relativeToChunk
    var affectedNeighbours: [CardinalDirection] = []
    if updateRelativeToChunk.z == 0 {
      affectedNeighbours.append(.north)
    } else if updateRelativeToChunk.z == 15 {
      affectedNeighbours.append(.south)
    }
    if updateRelativeToChunk.x == 15 {
      affectedNeighbours.append(.east)
    } else if updateRelativeToChunk.x == 0 {
      affectedNeighbours.append(.west)
    }
    
    for direction in affectedNeighbours {
      let neighbourChunk = blockUpdate.position.chunk.neighbour(inDirection: direction)
      let neighbourSection = ChunkSectionPosition(neighbourChunk, sectionY: updateRelativeToChunk.sectionIndex)
      affectedSections.append(neighbourSection)
    }
    
    // check whether sections above and below are also affected
    let updatedSection = blockUpdate.position.chunkSection
    
    let sectionHeight = Chunk.Section.height
    if updateRelativeToChunk.y % sectionHeight == sectionHeight - 1 && updateRelativeToChunk.y != Chunk.height - 1 {
      var section = updatedSection
      section.sectionY += 1
      affectedSections.append(section)
    } else if updateRelativeToChunk.y % sectionHeight == 0 && updateRelativeToChunk.y != 0 {
      var section = updatedSection
      section.sectionY -= 1
      affectedSections.append(section)
    }
    
    return affectedSections
  }
  
  /// Returns the positions of all valid chunk sections that neighbour the specific chunk section.
  private func sectionsNeighbouring(sectionAt sectionPosition: ChunkSectionPosition) -> [ChunkSectionPosition] {
    var northNeighbour = sectionPosition
    northNeighbour.sectionZ -= 1
    var eastNeighbour = sectionPosition
    eastNeighbour.sectionX += 1
    var southNeighbour = sectionPosition
    southNeighbour.sectionZ += 1
    var westNeighbour = sectionPosition
    westNeighbour.sectionX -= 1
    var upNeighbour = sectionPosition
    upNeighbour.sectionY += 1
    var downNeighbour = sectionPosition
    downNeighbour.sectionY -= 1
    
    var neighbours = [northNeighbour, eastNeighbour, southNeighbour, westNeighbour]
    
    if upNeighbour.sectionY < Chunk.numSections {
      neighbours.append(upNeighbour)
    }
    if downNeighbour.sectionY >= 0 {
      neighbours.append(downNeighbour)
    }
    
    return neighbours
  }
  
  /// Gets the current world uniforms buffer and populates it with the transformation matrix for the given camera.
  private func getUniformsBuffer(for camera: Camera) -> MTLBuffer {
    let worldToClipSpace = camera.getFrustum().worldToClip
    var worldUniforms = Uniforms(transformation: worldToClipSpace)
    let buffer = worldUniformBuffers[worldUniformBufferIndex]
    worldUniformBufferIndex = (worldUniformBufferIndex + 1) % worldUniformBuffers.count
    buffer.contents().copyMemory(from: &worldUniforms, byteCount: MemoryLayout<Uniforms>.stride)
    return buffer
  }
  
  // MARK: Init helpers
  
  private static func createWorldUniformBuffers(device: MTLDevice, count: Int) throws -> [MTLBuffer] {
    var buffers: [MTLBuffer] = []
    for _ in 0..<count {
      guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: []) else {
        throw RenderError.failedtoCreateWorldUniformBuffers
      }
      
      uniformBuffer.label = "worldUniformBuffer"
      buffers.append(uniformBuffer)
    }
    return buffers
  }
  
  private static func createDepthState(device: MTLDevice) throws -> MTLDepthStencilState {
    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .lessEqual
    depthDescriptor.isDepthWriteEnabled = true
    
    guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
      log.critical("Failed to create depth stencil state")
      throw RenderError.failedToCreateWorldDepthStencilState
    }
    
    return depthState
  }
  
  private static func createRenderPipelineState(vertex: MTLFunction, fragment: MTLFunction, device: MTLDevice) throws -> MTLRenderPipelineState {
    let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
    pipelineStateDescriptor.label = "dev.stackotter.delta-client.WorldRenderer"
    pipelineStateDescriptor.vertexFunction = vertex
    pipelineStateDescriptor.fragmentFunction = fragment
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipelineStateDescriptor.depthAttachmentPixelFormat = .depth32Float
    
    // Setup blending operation
    pipelineStateDescriptor.colorAttachments[0].isBlendingEnabled = true
    pipelineStateDescriptor.colorAttachments[0].rgbBlendOperation = .add
    pipelineStateDescriptor.colorAttachments[0].alphaBlendOperation = .add
    pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
    pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
    
    do {
      return try device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
    } catch {
      log.critical("Failed to create render pipeline state")
      throw RenderError.failedToCreateWorldRenderPipelineState(error)
    }
  }
  
  private static func createArrayTexture(palette: TexturePalette, animationState: TexturePaletteAnimationState, device: MTLDevice, commandQueue: MTLCommandQueue) throws -> MTLTexture {
    do {
      return try palette.createTextureArray(
        device: device,
        animationState: animationState,
        commandQueue: commandQueue)
    } catch {
      log.critical("Failed to create texture array: \(error)")
      throw RenderError.failedToCreateBlockTextureArray(error)
    }
  }
}
