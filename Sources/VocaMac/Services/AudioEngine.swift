// AudioEngine.swift
// VocaMac
//
// Real-time microphone audio capture using AVAudioEngine.
// Captures audio in the format required by whisper.cpp (16kHz, mono, Float32 PCM).

import Foundation
import AVFoundation
import Accelerate

final class AudioEngine {

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private var isCurrentlyRecording = false
    private let bufferQueue = DispatchQueue(label: "com.vocamac.audio-buffer", qos: .userInteractive)
    private var audioConverter: AVAudioConverter?
    private var converterKey: ConverterKey?

    // Silence detection
    private var lastSoundTime: Date = Date()
    private var silenceThreshold: Float = 0.01
    private var silenceDuration: Double = 2.0
    private var maxDuration: TimeInterval = 60.0
    private var recordingStartTime: Date = Date()

    // Audio level throttling
    private var lastLevelReportTime: TimeInterval = 0
    private var lastReportedLevel: Float = 0.0
    private let levelReportInterval: TimeInterval = 1.0 / 8.0  // ~8 Hz
    private let levelReportDelta: Float = 0.03

    /// Target audio format for whisper.cpp
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000.0,
        channels: 1,
        interleaved: false
    )!

    private struct ConverterKey: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat

        init(_ format: AVAudioFormat) {
            self.sampleRate = format.sampleRate
            self.channelCount = format.channelCount
            self.commonFormat = format.commonFormat
        }
    }

    // MARK: - Callbacks

    /// Called with the current audio level (0.0 - 1.0) for UI visualization
    var onAudioLevel: ((Float) -> Void)?

    /// Called when silence is detected for the configured duration
    var onSilenceDetected: (() -> Void)?

    /// Called when max recording duration is reached
    var onMaxDurationReached: (() -> Void)?

    // MARK: - Permission Handling

    /// Check current microphone permission status (tri-state)
    func checkPermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Request microphone permission from the user
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Recording Control

    /// Start recording audio from the microphone
    /// - Parameters:
    ///   - silenceThreshold: RMS energy threshold below which audio is considered silence
    ///   - silenceDuration: Seconds of silence before triggering silence detection callback
    ///   - maxDuration: Maximum recording duration in seconds
    func startRecording(
        silenceThreshold: Float = 0.01,
        silenceDuration: Double = 2.0,
        maxDuration: TimeInterval = 60.0
    ) {
        guard !isCurrentlyRecording else { return }

        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.maxDuration = maxDuration

        // Reset state
        bufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
        }
        lastLevelReportTime = 0
        lastReportedLevel = 0.0
        lastSoundTime = Date()
        recordingStartTime = Date()
        silenceCallbackFired = false
        maxDurationCallbackFired = false
        isCurrentlyRecording = true

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap on the input node to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, inputFormat: inputFormat)
        }

        do {
            try engine.start()
        } catch {
            VocaLogger.error(.audioEngine, "Failed to start audio engine: \(error)")
            isCurrentlyRecording = false
        }
    }

    /// Stop recording and return the captured audio samples
    /// - Returns: Array of Float32 PCM samples at 16kHz mono
    func stopRecording() -> [Float] {
        guard isCurrentlyRecording else { return [] }

        isCurrentlyRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let samples: [Float] = bufferQueue.sync {
            let captured = audioBuffer
            audioBuffer = []
            audioBuffer.reserveCapacity(captured.count)
            return captured
        }

        return samples
    }

    // MARK: - Audio Processing

    /// Whether silence detection has already fired (prevents repeated callbacks)
    private var silenceCallbackFired = false

    /// Whether max duration callback has already fired
    private var maxDurationCallbackFired = false

    /// Process an incoming audio buffer from AVAudioEngine
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard isCurrentlyRecording else { return }

        // Convert to whisper format (16kHz, mono, Float32)
        guard let convertedBuffer = convertToWhisperFormat(buffer, from: inputFormat) else {
            return
        }

        // Calculate audio energy for level reporting and silence detection
        let energy = calculateRMSEnergy(convertedBuffer)

        // Report audio level (throttled)
        let now = CFAbsoluteTimeGetCurrent()
        let normalizedLevel = min(energy / 0.3, 1.0)  // Normalize to 0-1 range
        if Self.shouldReportAudioLevel(
            lastReportTime: lastLevelReportTime,
            now: now,
            lastReportedLevel: lastReportedLevel,
            currentLevel: normalizedLevel,
            minInterval: levelReportInterval,
            minDelta: levelReportDelta
        ) {
            lastLevelReportTime = now
            lastReportedLevel = normalizedLevel
            onAudioLevel?(normalizedLevel)
        }

        // Always append audio samples to the buffer BEFORE checking stop conditions.
        // This ensures no audio frames are discarded when silence or max duration
        // is detected — the triggering frame and any trailing audio are preserved.
        if let channelData = convertedBuffer.floatChannelData {
            let frameCount = Int(convertedBuffer.frameLength)
            bufferQueue.sync {
                audioBuffer.reserveCapacity(audioBuffer.count + frameCount)
                let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
                audioBuffer.append(contentsOf: samples)
            }
        }

        // Check max duration (fire callback only once)
        let elapsed = Date().timeIntervalSince(recordingStartTime)
        if elapsed >= maxDuration && !maxDurationCallbackFired {
            maxDurationCallbackFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onMaxDurationReached?()
            }
            return
        }

        // Silence detection
        if energy > silenceThreshold {
            lastSoundTime = Date()
            silenceCallbackFired = false  // Reset so silence can be detected again after speech resumes
        } else if Date().timeIntervalSince(lastSoundTime) >= silenceDuration && !silenceCallbackFired {
            silenceCallbackFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onSilenceDetected?()
            }
        }
    }

    /// Convert an audio buffer to whisper.cpp's required format (16kHz, mono, Float32)
    private func convertToWhisperFormat(
        _ buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let whisperFormat = AudioEngine.whisperFormat

        // If input is already in the right format, return as-is
        if inputFormat.sampleRate == whisperFormat.sampleRate
            && inputFormat.channelCount == whisperFormat.channelCount
            && inputFormat.commonFormat == whisperFormat.commonFormat {
            return buffer
        }

        // Create a converter
        let key = ConverterKey(inputFormat)
        if converterKey != key || audioConverter == nil {
            audioConverter = AVAudioConverter(from: inputFormat, to: whisperFormat)
            converterKey = key
        }

        guard let converter = audioConverter else {
            VocaLogger.error(.audioEngine, "Failed to create audio format converter")
            return nil
        }

        // Calculate output frame capacity based on sample rate ratio
        let ratio = whisperFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            VocaLogger.error(.audioEngine, "Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }

    /// Calculate the RMS (root mean square) energy of an audio buffer
    private func calculateRMSEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0.0 }

        var rms: Float = 0.0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameCount))
        return rms
    }

    static func shouldReportAudioLevel(
        lastReportTime: TimeInterval,
        now: TimeInterval,
        lastReportedLevel: Float,
        currentLevel: Float,
        minInterval: TimeInterval,
        minDelta: Float
    ) -> Bool {
        let timeDelta = now - lastReportTime
        let levelDelta = abs(currentLevel - lastReportedLevel)
        return timeDelta >= minInterval || levelDelta >= minDelta
    }

    // MARK: - Audio Device Enumeration

    /// List available audio input devices
    static func availableInputDevices() -> [AudioDevice] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        let defaultDevice = AVCaptureDevice.default(for: .audio)

        return devices.map { device in
            AudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultDevice?.uniqueID
            )
        }
    }
}

// MARK: - AudioDevice

/// Represents an available audio input device
struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}
