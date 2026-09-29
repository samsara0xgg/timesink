import Foundation
import Metal
import QuartzCore

struct SpaceTextureRequest: Sendable {
    let event: SpaceEvent
    let snapshot: SpaceSnapshot?
    let width: Int
    var key: String { "\(event.id):\(snapshot?.id ?? -1):\(width)" }
}

/// The render loop only looks up ready textures. Two workers prepare upcoming cards off the UI thread.
@MainActor
final class SpaceTextures {
    private struct Entry {
        let texture: MTLTexture
        var used: UInt64
        var cost: Int { texture.width * texture.height * 4 }
    }
    private let device: MTLDevice
    private var cache: [String: Entry] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var desired: [SpaceTextureRequest] = []
    private var tick: UInt64 = 0
    private var bytes = 0
    private let byteLimit = 96 * 1024 * 1024
    var onReady: (() -> Void)?
    let placeholder: MTLTexture
    private(set) var completed = 0
    var pendingCount: Int { jobs.count + desired.filter { cache[$0.key] == nil && jobs[$0.key] == nil }.count }

    init(device: MTLDevice) {
        self.device = device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: descriptor)!
        var pixel: [UInt8] = [18, 22, 25, 255]
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }

    func cached(event: SpaceEvent, snapshot: SpaceSnapshot?, highQuality: Bool) -> MTLTexture? {
        for width in highQuality ? [1600, 1200, 600] : [600, 1200, 1600] {
            let key = "\(event.id):\(snapshot?.id ?? -1):\(width)"
            if var entry = cache[key] {
                tick &+= 1
                entry.used = tick
                cache[key] = entry
                return entry.texture
            }
        }
        return nil
    }

    func prepare(_ requests: [SpaceTextureRequest]) {
        var seen = Set<String>()
        desired = requests.filter { seen.insert($0.key).inserted }
        // Let the at-most-two in-flight decodes finish; discard stale queued work immediately.
        // Keeping running jobs bounded also prevents rapid scrubbing from starting dozens of decoders.
        drain()
    }

    func cancel() {
        desired = []
        for task in jobs.values { task.cancel() }
        jobs = [:]
    }

    private func drain() {
        for request in desired where jobs.count < 2 && cache[request.key] == nil && jobs[request.key] == nil {
            jobs[request.key] = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) {
                    autoreleasepool { SpaceCardArtwork.raster(for: request.event, snapshot: request.snapshot, width: request.width) }
                }
                let raster = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                self.jobs.removeValue(forKey: request.key)
                if let raster, let texture = Self.upload(raster, device: self.device) {
                    self.tick &+= 1
                    self.cache[request.key] = Entry(texture: texture, used: self.tick)
                    self.bytes += texture.width * texture.height * 4
                    self.completed += 1
                    self.evict()
                } else {
                    self.desired.removeAll { $0.key == request.key }
                }
                self.onReady?()
                self.drain()
            }
        }
    }

    private func evict() {
        while bytes > byteLimit, let oldest = cache.min(by: { $0.value.used < $1.value.used }) {
            bytes -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
        }
    }

    static func upload(_ raster: SpaceRaster, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: raster.width, height: raster.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        raster.pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, raster.width, raster.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: raster.width * 4)
        }
        return texture
    }
}
