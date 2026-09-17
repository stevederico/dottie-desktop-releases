//
//  MetalAvatarView.swift
//  Dottie
//
//  Unified SwiftUI wrapper for the Metal-rendered glass orb avatar.
//

import SwiftUI
import MetalKit

// MARK: - MetalAvatarView

/// Premium avatar rendered with Metal shaders. Displays a glass orb
/// that reacts to agent state and audio levels.
struct MetalAvatarView: View {
    let agentState: AgentState
    var audioLevel: Float = 0
    var size: CGFloat = 160

    var body: some View {
        // Render at 1.6x to give glow room, then compensate with negative padding
        let renderSize = size * 1.6
        MetalAvatarRepresentable(agentState: agentState, audioLevel: audioLevel, size: renderSize)
            .frame(width: renderSize, height: renderSize)
            .padding(-(renderSize - size) / 2)
    }
}

// MARK: - NSViewRepresentable

/// AppKit bridge that hosts an MTKView for Metal avatar shaders.
struct MetalAvatarRepresentable: NSViewRepresentable {
    let agentState: AgentState
    let audioLevel: Float
    let size: CGFloat

    class Coordinator {
        var renderer: BaseMetalRenderer?
        var lastState: AgentState?
        var lastAudioLevel: Float?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            AppLogger.shared.warn("[MetalAvatarView] no Metal device")
            return MTKView()
        }
        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: size, height: size), device: device)

        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = .clear
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.sampleCount = 4
        mtkView.autoResizeDrawable = true
        mtkView.framebufferOnly = true

        // Retina: render at native pixel density
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        mtkView.layer?.contentsScale = scaleFactor

        if let renderer = MetalOrbRenderer(mtkView: mtkView) {
            context.coordinator.renderer = renderer
            renderer.agentState = agentState.floatValue
            renderer.audioLevel = audioLevel
        } else {
            AppLogger.shared.warn("[MetalAvatarView] Failed to create orb renderer")
        }

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        let coordinator = context.coordinator
        guard let renderer = coordinator.renderer else { return }

        let stateChanged = coordinator.lastState != agentState
        let audioChanged = coordinator.lastAudioLevel != audioLevel

        guard stateChanged || audioChanged else { return }

        coordinator.lastState = agentState
        coordinator.lastAudioLevel = audioLevel

        renderer.agentState = agentState.floatValue
        renderer.audioLevel = audioLevel
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        MetalAvatarView(agentState: .idle, size: 160)
        HStack(spacing: 20) {
            MetalAvatarView(agentState: .thinking, size: 80)
            MetalAvatarView(agentState: .listening, audioLevel: 0.5, size: 80)
            MetalAvatarView(agentState: .speaking, audioLevel: 0.7, size: 80)
        }
    }
    .padding(40)
    .background(Color.black.opacity(0.9))
}
