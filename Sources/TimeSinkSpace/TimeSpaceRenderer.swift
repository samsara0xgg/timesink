import AppKit
import MetalKit
import SwiftUI
import simd

struct SpaceCanvasView: NSViewRepresentable {
    @ObservedObject var state: SpaceState
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SpaceCanvasHost {
        let host = SpaceCanvasHost(events: state.events, position: state.position, zoom: state.zoom)
        host.canvas?.onTravel = { [weak state] in state?.travel($0) }
        host.canvas?.onSelect = { [weak state] in state?.select($0, focus: true) }
        host.canvas?.onZoom = { [weak state] in state?.setZoom($0) }
        host.canvas?.onKey = { [weak state] key in
            guard let state else { return }
            switch key {
            case 123:
                if state.isExpanded { state.pickSnapshot(state.snapshotIndex - 1) }
                else { state.select(state.index - 1) }
            case 124:
                if state.isExpanded { state.pickSnapshot(state.snapshotIndex + 1) }
                else { state.select(state.index + 1) }
            case 125: state.pickSnapshot(state.snapshotIndex + 1)
            case 126: state.pickSnapshot(state.snapshotIndex - 1)
            case 36: state.openOriginal()
            case 53: state.closeDetail()
            case 49: state.isFocused.toggle()
            default: break
            }
        }
        return host
    }

    func updateNSView(_ view: SpaceCanvasHost, context: Context) {
        view.canvas?.setTarget(position: state.position, focused: state.isFocused,
                               snapshot: state.snapshot, zoom: state.zoom, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: SpaceCanvasHost, coordinator: ()) {
        view.canvas?.stopAnimation()
        view.canvas?.cancelTextureWork()
    }
}

@MainActor
final class SpaceCanvasHost: NSView {
    private(set) var canvas: SpaceCanvas?

    init(events: [SpaceEvent], position: Float, zoom: Float) {
        super.init(frame: .zero)
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw SpaceRenderError.unavailable }
            let canvas = SpaceCanvas(frame: bounds, device: device)
            try canvas.prepare(events: events, position: position, zoom: zoom)
            canvas.autoresizingMask = [.width, .height]
            addSubview(canvas)
            self.canvas = canvas
        } catch {
            let label = NSTextField(wrappingLabelWithString: "时间空间暂时无法绘制。\n\(error.localizedDescription)\n仍可用下方时间条浏览记录、查看原图。")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private enum SpaceRenderError: LocalizedError {
    case unavailable
    var errorDescription: String? { "这台 Mac 无法初始化 Metal 渲染器。" }
}

private struct SpaceVertex {
    var position: SIMD4<Float>
    var uv: SIMD2<Float>
    var face: Float
    var padding: Float = 0
}

private struct SpaceUniforms {
    var transform: simd_float4x4
    var tint: SIMD4<Float>
    var options: SIMD4<Float>
}

/// Each spring carries its velocity across retargeting, so dragging can interrupt any transition.
private struct SpaceSpring {
    var value: Float
    var target: Float
    var velocity: Float = 0

    mutating func advance(_ dt: Float, response: Float) {
        let omega = 2 * Float.pi / response
        let offset = value - target
        let c = velocity + omega * offset
        let decay = exp(-omega * dt)
        value = target + (offset + c * dt) * decay
        velocity = (velocity - omega * c * dt) * decay
        if settled { value = target; velocity = 0 }
    }

    var settled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.002 }
    mutating func snap() { value = target; velocity = 0 }
}

@MainActor
final class SpaceCanvas: MTKView, MTKViewDelegate {
    var onTravel: ((Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onKey: ((UInt16) -> Void)?

    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var vertices: MTLBuffer!
    private var textureStore: SpaceTextures!
    private var preparedKey = ""
    private var events: [SpaceEvent] = []
    private var currentSnapshot: SpaceSnapshot?
    private var travel = SpaceSpring(value: 2, target: 2)
    private var expansion = SpaceSpring(value: 0, target: 0)
    private var zoom = SpaceSpring(value: SpaceState.defaultZoom, target: SpaceState.defaultZoom)
    private var magnifying = false
    private var animationLink: CADisplayLink?
    private var scrollSettleTask: Task<Void, Never>?
    private var lastFrameTime = CACurrentMediaTime()
    private var tracking: NSTrackingArea?
    private var mouseStart: NSPoint?
    private var dragged = false
    private var hovered: Int?
    private var hitRegions: [(Int, [CGPoint])] = []
    private var reduceMotion = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func prepare(events: [SpaceEvent], position: Float, zoom initialZoom: Float) throws {
        self.events = events
        travel = SpaceSpring(value: position, target: position)
        zoom = SpaceSpring(value: initialZoom, target: initialZoom)
        guard let device, let queue = device.makeCommandQueue() else { throw SpaceRenderError.unavailable }
        self.queue = queue
        textureStore = SpaceTextures(device: device)
        textureStore.onReady = { [weak self] in self?.needsDisplay = true }
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColor(red: 0.057, green: 0.067, blue: 0.074, alpha: 1)
        // No continuous render loop: only interaction and an unsettled spring request frames.
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        preferredFramesPerSecond = 60
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "spaceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "spaceFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthStencilPixelFormat
        descriptor.rasterSampleCount = sampleCount
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .sourceAlpha
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
        let mesh = Self.cubeVertices()
        vertices = device.makeBuffer(bytes: mesh, length: MemoryLayout<SpaceVertex>.stride * mesh.count)

        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        setAccessibilityElement(false)
        prepareTextures()
        needsDisplay = true
    }

    func setTarget(position: Float, focused: Bool, snapshot: SpaceSnapshot?, zoom scale: Float, reduceMotion: Bool) {
        let zoomChanged = !magnifying && abs(zoom.target - scale) > 0.005
        let changed = travel.target != position || expansion.target != (focused ? 1 : 0)
            || currentSnapshot?.id != snapshot?.id || self.reduceMotion != reduceMotion || zoomChanged
        guard changed else { return }
        if travel.target != position || expansion.target != (focused ? 1 : 0) { scrollSettleTask?.cancel() }
        travel.target = position
        expansion.target = focused ? 1 : 0
        currentSnapshot = snapshot
        if zoomChanged { zoom.target = SpaceState.clampedZoom(scale) }
        self.reduceMotion = reduceMotion
        prepareTextures()
        if reduceMotion || window?.occlusionState.contains(.visible) != true {
            travel.snap(); expansion.snap(); zoom.snap()
            stopAnimation()
            needsDisplay = true
        } else {
            startAnimation()
        }
    }

    private func startAnimation() {
        needsDisplay = true
        guard animationLink == nil, window?.occlusionState.contains(.visible) == true else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(animateFrame))
        animationLink = link
        link.add(to: .main, forMode: .common)
    }

    func stopAnimation() { animationLink?.invalidate(); animationLink = nil }
    func cancelTextureWork() { scrollSettleTask?.cancel(); textureStore?.cancel() }

    private func settleOnMemory() {
        scrollSettleTask?.cancel()
        // Rest on a whole memory so the enlarged foreground cannot stop half off screen.
        let delta = travel.target.rounded() - travel.target
        if abs(delta) > 0.0001 { applyTravel(delta) }
    }

    private func applyTravel(_ delta: Float) {
        let next = min(Float(max(0, events.count - 1)), max(0, travel.target + delta))
        onTravel?(delta)
        travel.target = next
        expansion.target = 0
        // SwiftUI updates metadata only at interval boundaries; motion stays local to the canvas.
        prepareTextures()
        if reduceMotion { travel.snap(); expansion.snap(); needsDisplay = true }
        else { startAnimation() }
    }

    @objc private func animateFrame() {
        guard window?.occlusionState.contains(.visible) == true else { stopAnimation(); return }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 0.05))
        lastFrameTime = now
        travel.advance(dt, response: 0.48)
        expansion.advance(dt, response: 0.60)
        zoom.advance(dt, response: 0.22)
        prepareTextures()
        needsDisplay = true
        if travel.settled && expansion.settled && zoom.settled { stopAnimation() }
    }

    @objc private func visibilityChanged() {
        if window?.occlusionState.contains(.visible) == true {
            if !travel.settled || !expansion.settled || !zoom.settled { startAnimation() }
        } else { stopAnimation() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() } else { needsDisplay = true; visibilityChanged() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseDown(with event: NSEvent) {
        scrollSettleTask?.cancel()
        window?.makeFirstResponder(self)
        mouseStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseStart, hypot(point.x - start.x, point.y - start.y) > 4 { dragged = true }
        if dragged {
            NSCursor.closedHand.set()
            applyTravel(Float(-event.deltaX + event.deltaY) * 0.015)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged, let index = hitTestEvent(convert(event.locationInWindow, from: nil)) { onSelect?(index) }
        if dragged { settleOnMemory() }
        mouseStart = nil
        NSCursor.openHand.set()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !magnifying else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        applyTravel(-Float(delta) * (event.hasPreciseScrollingDeltas ? 0.012 : 0.18))
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            self?.settleOnMemory()
        }
    }

    override func magnify(with event: NSEvent) {
        if !magnifying {
            // Finish any residual travel before changing only the viewing distance.
            settleOnMemory()
            magnifying = true
        }
        zoom.target = SpaceState.clampedZoom(zoom.target * (1 + Float(event.magnification)))
        onZoom?(zoom.target)
        if reduceMotion { zoom.snap(); needsDisplay = true }
        else { startAnimation() }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { magnifying = false }
    }

    override func mouseMoved(with event: NSEvent) {
        let next = hitTestEvent(convert(event.locationInWindow, from: nil))
        if next != hovered { hovered = next; needsDisplay = true }
        if next == nil { NSCursor.openHand.set() } else { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126, 36, 53, 49].contains(event.keyCode) { onKey?(event.keyCode) }
        else { super.keyDown(with: event) }
    }

    private func hitTestEvent(_ point: CGPoint) -> Int? {
        // Painter order is far-to-near; frontmost visible face wins hit testing.
        for (index, corners) in hitRegions.reversed() {
            var positive = false, negative = false
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                positive = positive || cross > 0
                negative = negative || cross < 0
            }
            if !(positive && negative) { return index }
        }
        return nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard !events.isEmpty, bounds.width > 0, bounds.height > 0,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        let focus = expansion.value
        let chosen = min(events.count - 1, max(0, Int(travel.target.rounded())))
        let aspect = Float(bounds.width / bounds.height)
        let look = mix(SIMD3<Float>(0, -0.22, 0), SIMD3<Float>(0, -0.1, 0.3), focus)
        let direction = simd_normalize(mix(SIMD3<Float>(0.18, 0.025, 1), SIMD3<Float>(0, 0, 1), focus))
        let panelSize = mix(SIMD3<Float>(5.4, 3.6, 0.035), SIMD3<Float>(5.65, 3.767, 0.035), focus)
        let distance = fittedCameraDistance(size: panelSize, direction: direction, aspect: aspect,
                                            fill: (0.96 + focus * 0.02) * zoom.value)
        let eye = look + direction * distance
        let vp = perspective(fov: 0.64, aspect: aspect, near: 0.1, far: 120) * lookAt(eye: eye, target: look)
        let fallbackTexture = textureStore.placeholder

        func box(_ position: SIMD3<Float>, _ scale: SIMD3<Float>, _ tint: SIMD3<Float>, opacity: Float,
                 emphasis: Float = 0, texture: MTLTexture? = nil, solid: Bool = false) -> simd_float4x4 {
            let transform = vp * modelMatrix(position: position, scale: scale)
            var uniforms = SpaceUniforms(transform: transform, tint: SIMD4(tint, 1), options: SIMD4(opacity, emphasis, 1, solid ? 1 : 0))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SpaceUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpaceUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture ?? fallbackTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
            return transform
        }

        if focus < 0.99 {
            for x: Float in [-2.86, 2.86] {
                _ = box([x, -2.15, -10], [0.008, 0.008, 29], [0.39, 0.45, 0.47], opacity: 0.24 * (1 - focus), solid: true)
            }
        }

        struct Panel {
            let event: SpaceEvent
            let position: SIMD3<Float>
            let scale: SIMD3<Float>
            let opacity: Float
            let distance: Float
        }
        var panels: [Panel] = []
        let firstVisible = max(0, Int(floor(travel.value)) - 2)
        let lastVisible = min(events.count - 1, Int(ceil(travel.value)) + 12)
        for event in events[firstVisible...lastVisible] {
            let relative = Float(event.id) - travel.value
            guard relative > -2.5, relative < 12 else { continue }
            let selected = event.id == chosen
            let past = max(0, -relative)
            var position = SIMD3<Float>(-past * 6.6, -0.22, -relative * 1.7)
            var scale = SIMD3<Float>(5.4, 3.6, 0.035)
            if selected {
                position = mix(position, SIMD3<Float>(0, -0.1, 0.3), focus)
                scale = mix(scale, SIMD3<Float>(5.65, 3.767, 0.035), focus)
            } else {
                position.x += (event.id < chosen ? -1 : 1) * focus * 6.3
            }
            let opacity = (relative < -0.4 ? max(0, 0.42 + relative * 0.16) : max(0.13, 1 - relative * 0.078))
                * (selected ? 1 : 1 - focus * 0.82)
            panels.append(Panel(event: event, position: position, scale: scale, opacity: opacity,
                                distance: simd_length_squared(eye - position)))
        }
        panels.sort { $0.distance > $1.distance }
        hitRegions.removeAll(keepingCapacity: true)
        for panel in panels {
            let selected = panel.event.id == chosen
            // A real two-frame stack hints at the process inside a sustained memory.
            if selected, panel.event.availableSnapshots.count > 1 {
                for layer in (1...2).reversed() {
                    let snapshots = panel.event.availableSnapshots
                    let snapshot = snapshots[min(snapshots.count - 1, layer == 1 ? 0 : snapshots.count - 1)]
                    if let texture = textureStore.cached(event: panel.event, snapshot: snapshot, highQuality: false) {
                        _ = box(panel.position + SIMD3<Float>(Float(layer) * 0.12, Float(layer) * 0.09, -Float(layer) * 0.09),
                                panel.scale, panel.event.category.rgb, opacity: panel.opacity * 0.60, texture: texture)
                    }
                }
            }
            let snapshot = selected ? selectedSnapshot(for: panel.event) : panel.event.cover
            let texture = textureStore.cached(event: panel.event, snapshot: snapshot, highQuality: selected) ?? textureStore.placeholder
            let transform = box(panel.position, panel.scale, panel.event.category.rgb, opacity: panel.opacity,
                                emphasis: selected ? 1 : (hovered == panel.event.id ? 0.55 : 0), texture: texture)
            if panel.opacity > 0.15 {
                let local: [SIMD4<Float>] = [[-0.5, 0.5, 0.501, 1], [0.5, 0.5, 0.501, 1], [0.5, -0.5, 0.501, 1], [-0.5, -0.5, 0.501, 1]]
                let projected = local.map { transform * $0 }
                if projected.allSatisfy({ $0.w > 0.1 }) {
                    let points = projected.map { p in CGPoint(x: CGFloat(p.x / p.w + 1) * bounds.width / 2, y: CGFloat(1 - p.y / p.w) * bounds.height / 2) }
                    hitRegions.append((panel.event.id, points))
                }
            }
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func selectedSnapshot(for event: SpaceEvent) -> SpaceSnapshot? {
        currentSnapshot.flatMap { candidate in event.availableSnapshots.first { $0.id == candidate.id } } ?? event.cover
    }

    private func prepareTextures() {
        guard !events.isEmpty else { return }
        let index = min(events.count - 1, max(0, Int(travel.target.rounded())))
        let event = events[index]
        // The selected capture belongs only to the currently selected interval.
        let available = event.availableSnapshots
        let selected = selectedSnapshot(for: event)
        let visibleIndex = min(events.count - 1, max(0, Int(travel.value.rounded())))
        let key = "\(index):\(visibleIndex):\(selected?.id ?? -1)"
        guard key != preparedKey else { return }
        preparedKey = key
        var requests = [SpaceTextureRequest(event: event, snapshot: selected, width: 1600)]
        // A long timeline jump can put the spring far from its destination. Prepare what the
        // camera is passing through as well as the destination, without doing I/O in draw().
        if visibleIndex != index {
            for offset in [0, 1, -1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] {
                let passing = visibleIndex + offset
                guard events.indices.contains(passing) else { continue }
                let passingEvent = events[passing]
                requests.append(SpaceTextureRequest(event: passingEvent, snapshot: passingEvent.cover, width: 600))
            }
        }
        for distance in 1...14 {
            for neighbor in [index + distance, index - distance] where events.indices.contains(neighbor) && (neighbor >= index || distance <= 5) {
                let neighborEvent = events[neighbor]
                requests.append(SpaceTextureRequest(event: neighborEvent, snapshot: neighborEvent.cover, width: 600))
                if distance <= 2 { requests.append(SpaceTextureRequest(event: neighborEvent, snapshot: neighborEvent.cover, width: 1200)) }
            }
        }
        if let selected, let frameIndex = available.firstIndex(where: { $0.id == selected.id }) {
            for neighbor in [frameIndex - 1, frameIndex + 1] where available.indices.contains(neighbor) {
                requests.insert(SpaceTextureRequest(event: event, snapshot: available[neighbor], width: 1600), at: 1)
            }
        }
        for snapshot in [available.first, available.last].compactMap({ $0 }) {
            requests.insert(SpaceTextureRequest(event: event, snapshot: snapshot, width: 600), at: min(3, requests.count))
        }
        textureStore.prepare(requests)
    }

    private static func cubeVertices() -> [SpaceVertex] {
        var result: [SpaceVertex] = []
        let faces: [([SIMD3<Float>], Float)] = [
            ([[-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]], 1),
            ([[0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5]], 0),
            ([[-0.5, -0.5, -0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5]], 0.3),
            ([[0.5, -0.5, 0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5]], 0.3),
            ([[-0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]], 0.5),
            ([[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]], 0.2),
        ]
        let uvs: [SIMD2<Float>] = [[0, 1], [1, 1], [1, 0], [0, 0]]
        for (positions, face) in faces {
            for index in [0, 1, 2, 0, 2, 3] {
                result.append(SpaceVertex(position: SIMD4(positions[index], 1), uv: uvs[index], face: face))
            }
        }
        return result
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position; float2 uv; float face; float padding; };
    struct Uniforms { float4x4 transform; float4 tint; float4 options; };
    struct Varying { float4 position [[position]]; float2 uv; float face; };
    vertex Varying spaceVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Varying out;
        out.position = u.transform * vertices[id].position;
        out.uv = vertices[id].uv;
        out.face = vertices[id].face;
        return out;
    }
    fragment float4 spaceFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(1)]], texture2d<float> image [[texture(0)]]) {
        if (u.options.w > 0.5) return float4(u.tint.rgb, u.options.x);
        float2 edge = min(in.uv, 1.0 - in.uv);
        float2 edgeWidth = max(fwidth(in.uv) * 1.1, float2(0.0015));
        float border = 1.0 - smoothstep(0.0, 1.0, min(edge.x / edgeWidth.x, edge.y / edgeWidth.y));
        float3 body = mix(float3(0.074, 0.097, 0.113), u.tint.rgb * 0.28, 0.32 + u.options.y * 0.12);
        body *= 0.76 + in.face * 0.24;
        body = mix(body, u.tint.rgb * (0.44 + u.options.y * 0.55), border);
        if (in.face > 0.9) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 ink = image.sample(s, in.uv);
            body = body * (1.0 - ink.a * u.options.z) + ink.rgb * u.options.z;
        }
        return float4(body, u.options.x);
    }
    """
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

private func modelMatrix(position: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(scale.x, 0, 0, 0), SIMD4(0, scale.y, 0, 0), SIMD4(0, 0, scale.z, 0), SIMD4(position, 1)))
}

private func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fov / 2), x = y / aspect, z = far / (near - far)
    return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
}

/// Fit all four corners, including the near edge of the tilted card, as the window resizes.
private func fittedCameraDistance(size: SIMD3<Float>, direction: SIMD3<Float>, aspect: Float, fill: Float) -> Float {
    let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), direction))
    let up = simd_cross(direction, right)
    let tangent = tan(Float(0.64) / 2)
    var distance: Float = 0
    for x: Float in [-0.5, 0.5] {
        for y: Float in [-0.5, 0.5] {
            let corner = SIMD3<Float>(x * size.x, y * size.y, size.z / 2)
            let depth = simd_dot(corner, direction)
            distance = max(distance, abs(simd_dot(corner, right)) / (tangent * aspect * fill) + depth,
                           abs(simd_dot(corner, up)) / (tangent * fill) + depth)
        }
    }
    return distance
}

private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
    let z = simd_normalize(eye - target)
    let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z))
    let y = simd_cross(z, x)
    return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0), SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
}
