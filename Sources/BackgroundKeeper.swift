import AVFoundation

/// Keeps the process alive when OpenCode is sent to the background.
/// A zero-volume looping PCM stream is intentional: the audio session is what
/// tells iOS the app is still doing user-visible background work.
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var player: AVAudioPlayer?

    private init() {}

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        guard let data = Self.silentWave() else { return }
        player = try? AVAudioPlayer(data: data)
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.prepareToPlay()
        player?.play()
    }

    private static func silentWave() -> Data? {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let samples = Int(sampleRate)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataSize = UInt32(samples) * UInt32(blockAlign)
        var data = Data()
        func appendASCII(_ value: String) { data.append(value.data(using: .ascii)!) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendLE(UInt32(36) + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bits)
        appendASCII("data")
        appendLE(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}