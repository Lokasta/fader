import CoreAudio
import XCTest
@testable import Fader

final class GainRendererTests: XCTestCase {
    /// Owns the sample memory behind an AudioBufferList so tests can build arbitrary layouts.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        /// `layout` is the channel count of each buffer, e.g. [2] = one interleaved stereo buffer.
        init(layout: [Int], frames: Int, fill: (_ buffer: Int, _ channel: Int, _ frame: Int) -> Float = { _, _, _ in 0 }) {
            list = AudioBufferList.allocate(maximumBuffers: layout.count)
            for (index, channels) in layout.enumerated() {
                let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
                for frame in 0..<frames {
                    for channel in 0..<channels { samples[frame * channels + channel] = fill(index, channel, frame) }
                }
                storage.append(samples)
                list[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frames * 4), mData: samples)
            }
        }

        func sample(buffer: Int, channel: Int, frame: Int) -> Float {
            let channels = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * channels + channel]
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    func testUnityGainCopiesInterleavedStereo() {
        let input = Buffers(layout: [2], frames: 4) { _, channel, frame in channel == 0 ? Float(frame) * 0.1 : -0.2 }
        let output = Buffers(layout: [2], frames: 4) { _, _, _ in 9 }

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 0, rightChannel: 1, from: 1, to: 1)

        for frame in 0..<4 {
            XCTAssertEqual(output.sample(buffer: 0, channel: 0, frame: frame), Float(frame) * 0.1, accuracy: 1e-6)
            XCTAssertEqual(output.sample(buffer: 0, channel: 1, frame: frame), -0.2, accuracy: 1e-6)
        }
    }

    func testZeroGainSilences() {
        let input = Buffers(layout: [2], frames: 8) { _, _, _ in 0.5 }
        let output = Buffers(layout: [2], frames: 8)

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 0, rightChannel: 1, from: 0, to: 0)

        for frame in 0..<8 { XCTAssertEqual(output.sample(buffer: 0, channel: 0, frame: frame), 0) }
    }

    func testGainRampsAcrossBufferWithoutJumps() {
        let input = Buffers(layout: [2], frames: 100) { _, _, _ in 0.5 }
        let output = Buffers(layout: [2], frames: 100)

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 0, rightChannel: 1, from: 1, to: 0)

        var previous: Float = 0.5
        for frame in 0..<100 {
            let value = output.sample(buffer: 0, channel: 0, frame: frame)
            XCTAssertLessThanOrEqual(value, previous + 1e-6)
            XCTAssertLessThan(previous - value, 0.01, "step too large at frame \(frame)")
            previous = value
        }
        XCTAssertEqual(previous, 0, accuracy: 1e-6)
    }

    func testSkipsDeviceInputBuffers() {
        // Buffer 0 is a headset mic (must be ignored), buffer 1 is the tap.
        let input = Buffers(layout: [1, 2], frames: 4) { buffer, _, _ in buffer == 0 ? 0.9 : 0.25 }
        let output = Buffers(layout: [2], frames: 4)

        GainRenderer.render(input: input.list, inputBufferOffset: 1, output: output.list, leftChannel: 0, rightChannel: 1, from: 1, to: 1)

        XCTAssertEqual(output.sample(buffer: 0, channel: 0, frame: 2), 0.25, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 0, channel: 1, frame: 2), 0.25, accuracy: 1e-6)
    }

    func testNonInterleavedOutputAndCustomStereoPair() {
        let input = Buffers(layout: [2], frames: 4) { _, channel, _ in channel == 0 ? 0.1 : 0.3 }
        // 4 mono buffers, main pair on channels 3/4 (0-based 2/3).
        let output = Buffers(layout: [1, 1, 1, 1], frames: 4) { _, _, _ in 7 }

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 2, rightChannel: 3, from: 1, to: 1)

        XCTAssertEqual(output.sample(buffer: 0, channel: 0, frame: 1), 0)
        XCTAssertEqual(output.sample(buffer: 1, channel: 0, frame: 1), 0)
        XCTAssertEqual(output.sample(buffer: 2, channel: 0, frame: 1), 0.1, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 3, channel: 0, frame: 1), 0.3, accuracy: 1e-6)
    }

    func testMonoOutputMixesBothSides() {
        let input = Buffers(layout: [2], frames: 2) { _, channel, _ in channel == 0 ? 0.2 : 0.4 }
        let output = Buffers(layout: [1], frames: 2)

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 0, rightChannel: 1, from: 1, to: 1)

        XCTAssertEqual(output.sample(buffer: 0, channel: 0, frame: 1), 0.3, accuracy: 1e-6)
    }

    func testBoostNeverClips() {
        let input = Buffers(layout: [2], frames: 16) { _, _, _ in 0.9 }
        let output = Buffers(layout: [2], frames: 16)

        GainRenderer.render(input: input.list, inputBufferOffset: 0, output: output.list, leftChannel: 0, rightChannel: 1, from: 2, to: 2)

        for frame in 0..<16 {
            let value = output.sample(buffer: 0, channel: 0, frame: frame)
            XCTAssertLessThan(value, 1)
            XCTAssertGreaterThan(value, 0.9)
        }
    }

    func testSoftClipIsTransparentBelowKneeAndSymmetric() {
        XCTAssertEqual(GainRenderer.softClip(0.5), 0.5)
        XCTAssertEqual(GainRenderer.softClip(-0.5), -0.5)
        XCTAssertEqual(GainRenderer.softClip(3), -GainRenderer.softClip(-3), accuracy: 1e-6)
        XCTAssertLessThan(GainRenderer.softClip(100), 1.0001)
    }

    func testMissingTapInputLeavesSilence() {
        // Only the device's own input buffer arrived; the tap delivered nothing this cycle.
        let input = Buffers(layout: [1], frames: 4) { _, _, _ in 0.7 }
        let output = Buffers(layout: [2], frames: 4) { _, _, _ in 5 }

        GainRenderer.render(input: input.list, inputBufferOffset: 1, output: output.list, leftChannel: 0, rightChannel: 1, from: 1, to: 1)

        XCTAssertEqual(output.sample(buffer: 0, channel: 1, frame: 3), 0)
    }
}
