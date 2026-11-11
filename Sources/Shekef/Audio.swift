import AVFoundation
import AppKit

/// כל הסאונד עובר כאן, לא דרך הדפדפן: אפקטים, קובצי שמע, והקראה בקול עברי של המק.
final class AudioEngine: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var sfxPlayers: [AVAudioPlayer] = []
    private var voice: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var onEnd: (() -> Void)?
    private(set) var currentKey: String?

    override init() { super.init(); synth.delegate = self }

    func sfx(_ name: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("sounds/\(name).wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        sfxPlayers.removeAll { !$0.isPlaying }
        p.volume = 0.8; p.play(); sfxPlayers.append(p)
    }

    var debugState: String { "key=\(currentKey ?? "nil") playing=\(voice?.isPlaying ?? false) t=\(voice?.currentTime ?? -1) speaking=\(synth.isSpeaking)" }

    func stopVoice() {
        voice?.stop(); voice = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        let cb = onEnd; onEnd = nil; currentKey = nil; cb?()
    }

    @discardableResult
    func playFile(_ url: URL, key: String, onEnd: (() -> Void)? = nil) -> Bool {
        stopVoice()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        p.delegate = self; voice = p; self.onEnd = onEnd; currentKey = key
        return p.play()
    }

    static var hebrewVoice: AVSpeechSynthesisVoice? = {
        let he = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("he") }
        return he.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "he-IL")
    }()

    func speak(_ text: String, key: String, onEnd: (() -> Void)? = nil) {
        stopVoice()
        guard !text.isEmpty else { onEnd?(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.hebrewVoice
        u.rate = 0.44
        self.onEnd = onEnd; currentKey = key
        synth.speak(u)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if player === self.voice { self.voice = nil; self.finish() } }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.voice == nil { self.finish() } }
    }
}
