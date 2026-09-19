import AVFoundation
import AppKit

/// Plays a short key click without making keyboard input depend on a bundled asset.
/// A user supplied Resources/KeyboardKey.caf wins; the standard macOS Tink sound is the
/// fallback used by the debug build until a custom resource is added.
final class KeyboardSoundPlayer {
    var enabled = true
    var volume: Float = 0.35

    private let audioData: Data?
    private let namedFallback: Bool
    private var activePlayers: [AVAudioPlayer] = []

    init() {
        let candidate = Bundle.main.url(forResource: "KeyboardKey", withExtension: "caf")
        let tinkURL = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        if let candidate, let data = try? Data(contentsOf: candidate), !data.isEmpty {
            audioData = data
            namedFallback = false
            log("🔊 Keyboard sound: custom KeyboardKey.caf")
        } else if let data = try? Data(contentsOf: tinkURL), !data.isEmpty {
            audioData = data
            namedFallback = false
            log("🔊 Keyboard sound: system Tink fallback")
        } else if NSSound(named: NSSound.Name("Tink")) != nil {
            audioData = nil
            namedFallback = true
            log("🔊 Keyboard sound: named Tink fallback")
        } else {
            audioData = nil
            namedFallback = false
            log("⚠️ Keyboard sound unavailable")
        }
    }

    func play() {
        guard enabled else { return }
        activePlayers.removeAll { !$0.isPlaying }

        if let audioData {
            guard let player = try? AVAudioPlayer(data: audioData) else { return }
            player.volume = volume
            player.prepareToPlay()
            activePlayers.append(player)
            player.play()
            return
        }

        guard namedFallback, let sound = NSSound(named: NSSound.Name("Tink")) else { return }
        sound.volume = volume
        sound.play()
    }
}
