//
//  BaseMetalRenderer.swift
//  Dottie
//
//  Metal orb renderer + shared draw loop (orb is the only Metal avatar variant).
//

import MetalKit
import AppKit
import simd

// MARK: - Uniforms (matches Metal struct — identical layout for both shaders)

struct MetalRendererUniforms {
    var time: Float = 0
    var resolution: SIMD2<Float> = .zero
    var agentState: Float = 0      // 0=idle, 1=hover, 2=thinking, 3=listening, 4=speaking
    var audioLevel: Float = 0      // 0.0 - 1.0
    var distortion: Float = 0.15   // base distortion
    var iridescence: Float = 0.6   // iridescence intensity
    var touchStrength: Float = 0.0 // audio reactivity
    var hue: Float = 200.0         // color hue (0-360)
    var proactiveGlow: Float = 0.0 // transient notification glow (0.0 - 1.0)
    var reduceMotion: Float = 0.0  // 1.0 = accessibility reduce motion enabled
}

// MARK: - State Targets

/// Target uniform values for each agent state, smoothly interpolated per frame.
struct RendererStateTarget {
    let distortion: Float
    let iridescence: Float
    let touchStrength: Float

    static func target(for state: Float, targets: RendererStateTargets) -> RendererStateTarget {
        switch Int(state) {
        case 1: return targets.hover
        case 2: return targets.thinking
        case 3: return targets.listening
        case 4: return targets.speaking
        default: return targets.idle
        }
    }
}

/// Full set of state targets — each subclass provides its own.
struct RendererStateTargets {
    let idle: RendererStateTarget
    let hover: RendererStateTarget
    let thinking: RendererStateTarget
    let listening: RendererStateTarget
    let speaking: RendererStateTarget
}

// MARK: - AgentState Extension

extension AgentState {
    /// Maps AgentState to float for Metal shader uniforms.
    var floatValue: Float {
        switch self {
        case .idle: return 0
        case .hover: return 1
        case .thinking: return 2
        case .listening: return 3
        case .speaking: return 4
        }
    }
}

// MARK: - Base Renderer

/// Abstract base class for Metal renderers. Subclasses provide shader names,
/// state targets, and initial smoothing values via overridable properties.
class BaseMetalRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

    var uniforms = MetalRendererUniforms()
    let startTime = CACurrentMediaTime()

    // Smoothed values for interpolation
    var currentDistortion: Float
    var currentIridescence: Float
    var currentTouchStrength: Float = 0.0
    var currentAudioLevel: Float = 0.0
    var currentProactiveGlow: Float = 0.0

    /// Cached accessibility reduce motion preference.
    var isReduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Cached user hue preference from UserDefaults.
    var cachedHue: Float = Float(UserDefaults.standard.double(forKey: "metalOrbHue"))

    /// Current agent state (set from SwiftUI).
    var agentState: Float = 0 {
        didSet {
            targetDirty = true
            updateIdleFrameRate()
        }
    }

    /// Current audio level (set from SwiftUI, 0.0 - 1.0).
    var audioLevel: Float = 0

    /// Proactive glow intensity -- set to 1.0 on trigger, decays via lerp.
    var proactiveGlow: Float = 0.0

    var targetDirty = true

    /// Weak reference to MTKView for frame rate adjustments.
    weak var mtkView: MTKView?

    /// State targets for this renderer variant. Subclasses must override.
    var stateTargets: RendererStateTargets {
        fatalError("Subclasses must override stateTargets")
    }

    /// Display name for log messages. Subclasses must override.
    var logTag: String {
        fatalError("Subclasses must override logTag")
    }

    // MARK: - Init

    init?(mtkView: MTKView, vertexName: String, fragmentName: String, initialDistortion: Float, initialIridescence: Float) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else {
            AppLogger.shared.warn("[BaseMetalRenderer] No Metal device available")
            return nil
        }
        self.device = device
        mtkView.device = device

        guard let queue = device.makeCommandQueue() else {
            AppLogger.shared.warn("[BaseMetalRenderer] Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        // Load shader library
        guard let library = device.makeDefaultLibrary() else {
            AppLogger.shared.warn("[BaseMetalRenderer] Failed to load default Metal library")
            return nil
        }

        guard let vertexFn = library.makeFunction(name: vertexName),
              let fragmentFn = library.makeFunction(name: fragmentName) else {
            AppLogger.shared.warn("[BaseMetalRenderer] Failed to find shader functions: \(vertexName), \(fragmentName)")
            return nil
        }

        // Pipeline descriptor
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        desc.sampleCount = mtkView.sampleCount

        // Alpha blending for transparent background
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            AppLogger.shared.warn("[BaseMetalRenderer] Pipeline state error: \(error)")
            return nil
        }

        self.currentDistortion = initialDistortion
        self.currentIridescence = initialIridescence

        super.init()

        self.mtkView = mtkView

        // Configure MTKView
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.layer?.isOpaque = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.delegate = self

        // Observe proactive glow triggers from AvatarPanelManager
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleProactiveGlow),
            name: .triggerProactiveGlow, object: nil
        )

        // Observe accessibility reduce motion changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleAccessibilityChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )

        // Observe UserDefaults hue changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDefaultsChange),
            name: UserDefaults.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Proactive Glow

    @objc private func handleProactiveGlow() {
        DispatchQueue.main.async { [weak self] in
            self?.proactiveGlow = 1.0
            // Animate the flash at full rate; draw() restores 15fps once idle and glow fully decays.
            self?.mtkView?.preferredFramesPerSecond = 60
        }
    }

    @objc private func handleAccessibilityChange() {
        isReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func handleDefaultsChange() {
        cachedHue = Float(UserDefaults.standard.double(forKey: "metalOrbHue"))
    }

    // MARK: - Idle Frame Rate

    /// Reduce to 15fps during idle to save GPU/battery. Restore to 60fps for active states.
    private func updateIdleFrameRate() {
        let isIdle = Int(agentState) == 0
        mtkView?.preferredFramesPerSecond = isIdle ? 15 : 60
    }

    // MARK: - Time-of-Day Hue Offset

    /// Computes additive hue offset based on current hour.
    /// 6-9am: +15 warm, 9am-5pm: +0 neutral, 5-8pm: +10 warm, 8pm-6am: -10 cool.
    func timeOfDayHueOffset() -> Float {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<9: return 15.0
        case 9..<17: return 0.0
        case 17..<20: return 10.0
        default: return -10.0 // 8pm-6am: cool
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor else { return }

        // Clear to transparent
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDesc.colorAttachments[0].loadAction = .clear

        // Update time
        uniforms.time = Float(CACurrentMediaTime() - startTime)
        uniforms.resolution = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        // Smooth interpolation toward target state
        let target = RendererStateTarget.target(for: agentState, targets: stateTargets)
        let lerpSpeed: Float = 0.12 // ~8 frames to settle at 60fps

        currentDistortion += (target.distortion - currentDistortion) * lerpSpeed
        currentIridescence += (target.iridescence - currentIridescence) * lerpSpeed
        currentTouchStrength += (target.touchStrength - currentTouchStrength) * lerpSpeed
        currentAudioLevel += (audioLevel - currentAudioLevel) * 0.25 // Fast response for speech

        // Proactive glow: decay toward 0 (~1.3s fade at 60fps)
        currentProactiveGlow += (proactiveGlow - currentProactiveGlow) * 0.05
        if currentProactiveGlow < 0.01 { currentProactiveGlow = 0 }
        proactiveGlow = max(proactiveGlow - 0.02, 0) // target decays toward 0
        // Once the glow has fully faded and we're idle, drop back to the 15fps idle rate.
        if currentProactiveGlow == 0 && proactiveGlow == 0 && Int(agentState) == 0 {
            if view.preferredFramesPerSecond != 15 { view.preferredFramesPerSecond = 15 }
        }

        // Time-of-day hue offset (additive to user's chosen hue)
        let hueOffset = timeOfDayHueOffset()
        let finalHue = fmod(cachedHue + hueOffset + 360.0, 360.0)

        uniforms.agentState = agentState
        uniforms.audioLevel = currentAudioLevel
        uniforms.distortion = currentDistortion
        uniforms.iridescence = currentIridescence
        uniforms.touchStrength = currentTouchStrength
        uniforms.hue = finalHue
        uniforms.proactiveGlow = currentProactiveGlow
        uniforms.reduceMotion = isReduceMotion ? 1.0 : 0.0

        // Encode draw call
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalRendererUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Metal Orb Renderer
// MARK: - Orb State Targets

private let orbStateTargets = RendererStateTargets(
    idle: RendererStateTarget(distortion: 0.12, iridescence: 0.3, touchStrength: 0.0),
    hover: RendererStateTarget(distortion: 0.15, iridescence: 0.7, touchStrength: 0.0),
    thinking: RendererStateTarget(distortion: 0.15, iridescence: 0.6, touchStrength: 0.1),
    listening: RendererStateTarget(distortion: 0.12, iridescence: 0.45, touchStrength: 1.0),
    speaking: RendererStateTarget(distortion: 0.20, iridescence: 0.5, touchStrength: 0.5)
)

// MARK: - Renderer

final class MetalOrbRenderer: BaseMetalRenderer {

    override var stateTargets: RendererStateTargets { orbStateTargets }
    override var logTag: String { "MetalOrbRenderer" }

    init?(mtkView: MTKView) {
        super.init(
            mtkView: mtkView,
            vertexName: "metalOrbVertex",
            fragmentName: "metalOrbFragment",
            initialDistortion: 0.08,
            initialIridescence: 0.4
        )
    }
}

