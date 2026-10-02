import CoreAudio
import Synchronization

/// Shared between the UI (writes the target gain) and the real-time audio thread (reads it).
/// Everything the audio thread touches lives here so the IO block never allocates or locks.
final class RenderContext: @unchecked Sendable {
    private let targetBits = Atomic<UInt32>(Float(1).bitPattern)
    private let peak = PeakBox()

    /// Only touched by the audio thread after the IO proc starts.
    var currentGain: Float = 1
    /// Input buffers before this index belong to the output device itself (e.g. a headset mic), not the tap.
    let inputBufferOffset: Int
    let leftChannel: Int
    let rightChannel: Int
    /// False for metering taps: the app's audio still plays normally, we only measure it.
    let passesAudio: Bool

    init(inputBufferOffset: Int, leftChannel: Int, rightChannel: Int, passesAudio: Bool = true) {
        self.inputBufferOffset = inputBufferOffset
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.passesAudio = passesAudio
    }

    var targetGain: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Loudest sample as heard (after this app's gain) since the last call. Drives the level meters.
    func takePeak() -> Float { peak.take() }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let target = targetGain
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        let heard = passesAudio ? max(currentGain, target) : 1
        peak.raise(to: GainRenderer.peak(of: inputList, firstBuffer: inputBufferOffset) * heard)

        guard passesAudio else {
            for buffer in outputList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }
        GainRenderer.render(
            input: inputList,
            inputBufferOffset: inputBufferOffset,
            output: outputList,
            leftChannel: leftChannel,
            rightChannel: rightChannel,
            from: currentGain,
            to: target
        )
        currentGain = target
    }
}

enum GainRenderer {
    /// Above this level, boosted audio is bent smoothly toward 1.0 instead of hard clipping.
    static let softClipKnee: Float = 0.8

    struct Channel {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    /// Locates the n-th channel across a buffer list, interleaved or not. No allocation.
    static func channel(_ index: Int, in list: UnsafeMutableAudioBufferListPointer, firstBuffer: Int = 0) -> Channel? {
        var remaining = index
        guard firstBuffer < list.count else { return nil }
        for bufferIndex in firstBuffer..<list.count {
            let buffer = list[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            if remaining < channels {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return Channel(samples: data.assumingMemoryBound(to: Float.self) + remaining, stride: channels, frames: frames)
            }
            remaining -= channels
        }
        return nil
    }

    static func channelCount(in list: UnsafeMutableAudioBufferListPointer, firstBuffer: Int = 0) -> Int {
        guard firstBuffer < list.count else { return 0 }
        var total = 0
        for bufferIndex in firstBuffer..<list.count { total += Int(list[bufferIndex].mNumberChannels) }
        return total
    }

    static func peak(of list: UnsafeMutableAudioBufferListPointer, firstBuffer: Int) -> Float {
        guard firstBuffer < list.count else { return 0 }
        var peak: Float = 0
        for bufferIndex in firstBuffer..<list.count {
            let buffer = list[bufferIndex]
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                peak = max(peak, abs(samples[index]))
            }
        }
        return peak
    }

    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > softClipKnee else { return x }
        let headroom = 1 - softClipKnee
        let bent = softClipKnee + headroom * tanh((magnitude - softClipKnee) / headroom)
        return x < 0 ? -bent : bent
    }

    /// Copies the tap's stereo mix into the device's main stereo pair, applying a gain ramp
    /// from `from` to `to` across the buffer so volume changes never click.
    static func render(
        input: UnsafeMutableAudioBufferListPointer,
        inputBufferOffset: Int,
        output: UnsafeMutableAudioBufferListPointer,
        leftChannel: Int,
        rightChannel: Int,
        from startGain: Float,
        to endGain: Float
    ) {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let inputChannels = channelCount(in: input, firstBuffer: inputBufferOffset)
        guard inputChannels > 0, let inLeft = channel(0, in: input, firstBuffer: inputBufferOffset) else { return }
        let inRight = channel(min(1, inputChannels - 1), in: input, firstBuffer: inputBufferOffset) ?? inLeft
        let boosting = max(startGain, endGain) > 1

        if channelCount(in: output) == 1, let mono = channel(0, in: output) {
            let frames = min(mono.frames, inLeft.frames, inRight.frames)
            write(frames: frames, to: mono, boosting: boosting, from: startGain, to: endGain) { frame in
                0.5 * (inLeft.samples[frame * inLeft.stride] + inRight.samples[frame * inRight.stride])
            }
            return
        }

        copy(inLeft, toChannel: leftChannel, of: output, boosting: boosting, from: startGain, to: endGain)
        copy(inRight, toChannel: rightChannel, of: output, boosting: boosting, from: startGain, to: endGain)
    }

    @inline(__always)
    private static func copy(_ source: Channel, toChannel index: Int, of output: UnsafeMutableAudioBufferListPointer, boosting: Bool, from startGain: Float, to endGain: Float) {
        guard let out = channel(index, in: output) else { return }
        write(frames: min(out.frames, source.frames), to: out, boosting: boosting, from: startGain, to: endGain) { frame in
            source.samples[frame * source.stride]
        }
    }

    @inline(__always)
    private static func write(frames: Int, to out: Channel, boosting: Bool, from startGain: Float, to endGain: Float, sample: (Int) -> Float) {
        guard frames > 0 else { return }
        let step = (endGain - startGain) / Float(frames)
        var gain = startGain
        for frame in 0..<frames {
            gain += step
            let value = sample(frame) * gain
            out.samples[frame * out.stride] = boosting ? softClip(value) : value
        }
    }
}
