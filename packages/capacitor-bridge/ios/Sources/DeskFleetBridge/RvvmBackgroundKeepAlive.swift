// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import AVFoundation
import Foundation

/// Maintains an active background audio session with a silent looping 8 kHz WAV clip
/// so iOS does not suspend the embedded librvvm Linux daemon while the app is backgrounded.
internal final class RvvmBackgroundKeepAlive {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var active = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        active = true
        installObserversLocked()
        activatePlaybackLocked()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        player?.stop()
        player = nil
    }

    deinit {
        stop()
    }

    private func installObserversLocked() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
                      type == .ended else {
                    return
                }
                self?.resumeIfActive()
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.rebuildIfActive()
            },
        ]
    }

    private func resumeIfActive() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        activatePlaybackLocked()
    }

    private func rebuildIfActive() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        player?.stop()
        player = nil
        activatePlaybackLocked()
    }

    private func activatePlaybackLocked() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let audio = try AVAudioPlayer(data: Self.silentWavData())
                audio.numberOfLoops = -1
                audio.volume = 0.0
                audio.prepareToPlay()
                player = audio
            }
            if player?.isPlaying == false {
                player?.play()
            }
        } catch {
            // Keep-alive audio is best-effort; foreground VM execution continues even if audio session fails.
        }
    }

    /// Generates a 1-second 8 kHz 16-bit mono silent PCM WAV buffer in memory.
    internal static func silentWavData() -> Data {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataBytes: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let riffSize: UInt32 = 36 + dataBytes
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)

        var wav = Data(capacity: Int(44 + dataBytes))
        wav.append(contentsOf: "RIFF".utf8)
        appendLE(&wav, riffSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        appendLE(&wav, UInt32(16))
        appendLE(&wav, UInt16(1))
        appendLE(&wav, channels)
        appendLE(&wav, sampleRate)
        appendLE(&wav, byteRate)
        appendLE(&wav, blockAlign)
        appendLE(&wav, bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        appendLE(&wav, dataBytes)
        wav.append(Data(count: Int(dataBytes)))
        return wav
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
