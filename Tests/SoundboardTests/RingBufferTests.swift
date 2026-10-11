import AudioToolbox
import XCTest
@testable import Soundboard

/// Sample rate 1000 Hz makes the buffer's target 20 samples and its latency limit 80.
final class RingBufferTests: XCTestCase {
    private func write(_ buffer: RingBuffer, channels: [[Float]], interleaved: Bool = false) {
        let frames = channels[0].count
        let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels.count)
        defer { free(list.unsafeMutablePointer) }
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { storage.forEach { $0.deallocate() } }
        if interleaved {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels.count)
            for i in 0..<frames { for (c, channel) in channels.enumerated() { data[i * channels.count + c] = channel[i] } }
            storage.append(data)
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels.count), mDataByteSize: UInt32(frames * channels.count * 4), mData: data)
        } else {
            for (c, channel) in channels.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                data.initialize(from: channel, count: frames)
                storage.append(data)
                list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
            }
        }
        buffer.write(list, frames: frames)
    }

    private func read(_ buffer: RingBuffer, _ count: Int) -> (samples: [Float], audio: Int) {
        var out = [Float](repeating: 9, count: count)
        let n = out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, count: count) }
        return (out, n)
    }

    private func ramp(_ count: Int, from start: Float = 1) -> [Float] { (0..<count).map { start + Float($0) } }

    func testWaitsForTargetBeforePlaying() {
        let buffer = RingBuffer(sampleRate: 1000)
        write(buffer, channels: [ramp(10)])
        let early = read(buffer, 10)
        XCTAssertEqual(early.audio, 0)
        XCTAssertEqual(early.samples, [Float](repeating: 0, count: 10))
        write(buffer, channels: [ramp(10, from: 11)])
        let primed = read(buffer, 20)
        XCTAssertEqual(primed.audio, 20)
        XCTAssertEqual(primed.samples, ramp(20))
    }

    func testUnderrunPadsWithSilenceAndRearms() {
        let buffer = RingBuffer(sampleRate: 1000)
        write(buffer, channels: [ramp(30)])
        let result = read(buffer, 40)
        XCTAssertEqual(result.audio, 30)
        XCTAssertEqual(Array(result.samples[30...]), [Float](repeating: 0, count: 10))
        // Running dry means it waits for the target again.
        write(buffer, channels: [ramp(5)])
        XCTAssertEqual(read(buffer, 5).audio, 0)
    }

    func testSkipsAheadWhenBacklogPassesLimit() {
        let buffer = RingBuffer(sampleRate: 1000)
        write(buffer, channels: [ramp(100)])
        let result = read(buffer, 10)
        // Kept only the newest 20 samples (81…100), so the first read starts at 81.
        XCTAssertEqual(result.audio, 10)
        XCTAssertEqual(result.samples, ramp(10, from: 81))
    }

    func testDownmixesPlanarAndInterleavedChannelsToMono() {
        for interleaved in [false, true] {
            let buffer = RingBuffer(sampleRate: 1000)
            write(buffer, channels: [[Float](repeating: 1, count: 20), [Float](repeating: 3, count: 20)], interleaved: interleaved)
            XCTAssertEqual(read(buffer, 20).samples, [Float](repeating: 2, count: 20), "interleaved: \(interleaved)")
        }
    }

    func testWrapsAroundTheStorage() {
        let buffer = RingBuffer(sampleRate: 1000)
        var expected: [Float] = []
        var next: Float = 1
        for _ in 0..<5000 {
            write(buffer, channels: [ramp(30, from: next)])
            next += 30
            expected += read(buffer, 30).samples
        }
        // After the first priming read, every sample comes out in order with none lost.
        let audio = expected.filter { $0 != 0 }
        XCTAssertEqual(audio, ramp(audio.count, from: audio[0]))
    }
}
