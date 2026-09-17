//
//  AudioSpectrumAnalyzer.swift
//  Dottie
//
//  Created by Claude Code on 1/25/26.
//

import Foundation
import AVFoundation
import Accelerate
import QuartzCore

/// FFT-based audio spectrum analyzer for real-time frequency band extraction.
/// Uses vDSP for efficient signal processing.
class AudioSpectrumAnalyzer: ObservableObject {
    // MARK: - Published Properties (0.0 - 1.0 range)
    @Published var bassLevel: Float = 0.0
    @Published var midLevel: Float = 0.0
    @Published var trebleLevel: Float = 0.0

    // MARK: - FFT Configuration
    private let fftSize: Int = 256           // More frequency resolution
    private let smoothingFactor: Float = 0.3 // Lower = more responsive

    // Band split ratios (matching x-tv implementation)
    private let bassEndRatio: Float = 0.15   // 0-15% = bass
    private let midEndRatio: Float = 0.40    // 15-40% = mid
    // 40-100% = treble

    // Amplitude thresholds for silence detection
    private let silenceThreshold: Float = 0.005
    private let boostMultiplier: Float = 8.0  // High boost for dramatic effect

    // MARK: - vDSP FFT Setup
    private var fftSetup: vDSP_DFT_Setup?
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudeBuffer: [Float]

    /// Pre-computed Hann window — avoids per-frame allocation in FFT hot path.
    private var hannWindow: [Float]

    // Previous values for smoothing
    private var prevBass: Float = 0.0
    private var prevMid: Float = 0.0
    private var prevTreble: Float = 0.0

    // Coalesce the @Published main-thread dispatch to ~20 Hz. processBuffer fires
    // once per audio buffer (~10-43 Hz); without this gate every buffer schedules
    // a main-thread wakeup. Inline throttle (mirrors MessageStore.throttleInterval).
    private let publishInterval: CFTimeInterval = 0.05  // 20 Hz
    private var lastPublishTime: CFTimeInterval = 0

    /// Schedules the three @Published writes on the main thread, gated to ~20 Hz.
    /// `force` bypasses the gate (used by reset / final settle so the last value lands).
    private func publishLevels(_ bass: Float, _ mid: Float, _ treble: Float, force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force && (now - lastPublishTime) < publishInterval { return }
        lastPublishTime = now
        DispatchQueue.main.async { [weak self] in
            self?.bassLevel = bass
            self?.midLevel = mid
            self?.trebleLevel = treble
        }
    }

    /// Allocates FFT buffers, pre-computes the Hann window, and creates the vDSP DFT setup.
    init() {
        let halfFFT = fftSize / 2
        realBuffer = [Float](repeating: 0, count: fftSize)
        imagBuffer = [Float](repeating: 0, count: fftSize)
        magnitudeBuffer = [Float](repeating: 0, count: halfFFT)

        // Pre-compute Hann window once instead of every frame
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Create DFT setup for real-to-complex transform
        fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            .FORWARD
        )
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    /// Process an audio buffer and update frequency band levels.
    /// Call this from the audio tap callback.
    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // Skip if not enough samples
        guard frameCount >= fftSize else { return }

        // Copy samples to real buffer (use last fftSize samples if buffer is larger)
        let startIndex = max(0, frameCount - fftSize)
        for i in 0..<fftSize {
            realBuffer[i] = channelData[startIndex + i]
        }

        // Apply pre-computed Hann window for smoother FFT
        vDSP_vmul(realBuffer, 1, hannWindow, 1, &realBuffer, 1, vDSP_Length(fftSize))

        // Check overall RMS amplitude (time-domain, windowed) to detect silence —
        // must be read BEFORE the in-place DFT overwrites realBuffer with
        // frequency-domain data.
        var rms: Float = 0
        vDSP_rmsqv(realBuffer, 1, &rms, vDSP_Length(fftSize))

        // Zero out imaginary buffer (reuse existing allocation)
        vDSP_vclr(&imagBuffer, 1, vDSP_Length(fftSize))

        // Perform DFT
        guard let setup = fftSetup else { return }
        vDSP_DFT_Execute(setup, realBuffer, imagBuffer, &realBuffer, &imagBuffer)

        // If below silence threshold, quickly decay to zero
        if rms < silenceThreshold {
            let decayFactor: Float = 0.7
            prevBass *= decayFactor
            prevMid *= decayFactor
            prevTreble *= decayFactor

            publishLevels(prevBass, prevMid, prevTreble)
            return
        }

        // Calculate magnitudes (only need first half due to symmetry)
        let halfFFT = fftSize / 2
        for i in 0..<halfFFT {
            let real = realBuffer[i]
            let imag = imagBuffer[i]
            magnitudeBuffer[i] = sqrtf(real * real + imag * imag)
        }

        // DO NOT normalize to max - use absolute values for true silence detection
        // Instead, use a fixed reference level based on typical speech
        let referenceLevel: Float = Float(fftSize) * 0.5

        // Calculate band indices
        let bassEnd = Int(Float(halfFFT) * bassEndRatio)
        let midEnd = Int(Float(halfFFT) * midEndRatio)

        // Calculate average levels for each band
        var bassSum: Float = 0
        var midSum: Float = 0
        var trebleSum: Float = 0

        vDSP_sve(magnitudeBuffer, 1, &bassSum, vDSP_Length(bassEnd))

        let midStart = bassEnd
        let midCount = midEnd - midStart
        if midCount > 0 {
            vDSP_sve(Array(magnitudeBuffer[midStart..<midEnd]), 1, &midSum, vDSP_Length(midCount))
        }

        let trebleStart = midEnd
        let trebleCount = halfFFT - trebleStart
        if trebleCount > 0 {
            vDSP_sve(Array(magnitudeBuffer[trebleStart..<halfFFT]), 1, &trebleSum, vDSP_Length(trebleCount))
        }

        // Normalize by band width and reference level, then apply boost
        var rawBass = bassEnd > 0 ? (bassSum / Float(bassEnd)) / referenceLevel : 0
        var rawMid = midCount > 0 ? (midSum / Float(midCount)) / referenceLevel : 0
        var rawTreble = trebleCount > 0 ? (trebleSum / Float(trebleCount)) / referenceLevel : 0

        // Apply exponential curve for more dramatic response
        rawBass = powf(rawBass, 0.6) * boostMultiplier
        rawMid = powf(rawMid, 0.6) * boostMultiplier
        rawTreble = powf(rawTreble, 0.6) * boostMultiplier

        // Apply temporal smoothing (asymmetric - fast attack, slower decay)
        let attackFactor: Float = 0.2  // Fast response to increases
        let decayFactor: Float = 0.5   // Slower decay

        let smoothedBass = rawBass > prevBass
            ? prevBass * attackFactor + rawBass * (1 - attackFactor)
            : prevBass * decayFactor + rawBass * (1 - decayFactor)
        let smoothedMid = rawMid > prevMid
            ? prevMid * attackFactor + rawMid * (1 - attackFactor)
            : prevMid * decayFactor + rawMid * (1 - decayFactor)
        let smoothedTreble = rawTreble > prevTreble
            ? prevTreble * attackFactor + rawTreble * (1 - attackFactor)
            : prevTreble * decayFactor + rawTreble * (1 - decayFactor)

        // Store for next frame
        prevBass = smoothedBass
        prevMid = smoothedMid
        prevTreble = smoothedTreble

        // Update published values on main thread (clamp to 0-1), coalesced to ~20 Hz
        publishLevels(min(1.0, max(0.0, smoothedBass)),
                      min(1.0, max(0.0, smoothedMid)),
                      min(1.0, max(0.0, smoothedTreble)))
    }

    /// Reset all levels to zero (call when recording stops)
    func reset() {
        prevBass = 0
        prevMid = 0
        prevTreble = 0
        lastPublishTime = 0

        // Force past the throttle gate so the zeroed levels always land on stop.
        publishLevels(0, 0, 0, force: true)
    }
}
