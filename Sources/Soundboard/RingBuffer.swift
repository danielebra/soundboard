import AudioToolbox
import Synchronization

/// Lock-free single-producer / single-consumer mono sample buffer that carries the
/// microphone from its capture thread to the virtual-mic render thread.
///
/// The two sides run on different hardware clocks, so the reader keeps the fill level
/// near `target`: it waits for that much audio before starting, and skips ahead if the
/// backlog grows past `maxLatency`.
final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    private let target: Int
    private let maxLatency: Int
    /// Reader-thread only.
    private var primed = false

    init(sampleRate: Double) {
        capacity = 1 << 16
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        target = Int(sampleRate * 0.02)
        maxLatency = Int(sampleRate * 0.08)
    }

    deinit { storage.deallocate() }

    /// Capture thread. Downmixes all channels (interleaved or not) to mono.
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - r))
        guard n > 0 else { return }

        var total = 0
        for buffer in list { total += Int(buffer.mNumberChannels) }
        guard total > 0 else { return }
        let scale = 1 / Float(total)

        for i in 0..<n { storage[(w + i) & mask] = 0 }
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<stride { sum += data[i * stride + c] }
                storage[(w + i) & mask] += sum * scale
            }
        }
        writeIndex.store(w + n, ordering: .releasing)
    }

    /// Render thread. Always fills `count` samples (silence on underrun).
    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        var r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        var available = w - r

        if !primed {
            guard available >= target else {
                out.update(repeating: 0, count: count)
                return
            }
            primed = true
        }
        if available > maxLatency {
            r = w - target
            available = target
        }

        let n = min(count, available)
        for i in 0..<n { out[i] = storage[(r + i) & mask] }
        if n < count {
            (out + n).update(repeating: 0, count: count - n)
            primed = false
        }
        readIndex.store(r + n, ordering: .releasing)
    }
}
