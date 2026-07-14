import AVFAudio

extension AVAudioPCMBuffer {
    /// Deep copy of the buffer's samples. The engine tap's buffer is only
    /// guaranteed valid inside the tap block, so anything held past it
    /// (pre-roll, transcription hold buffer, async queues) must be a copy.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let bytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            memcpy(dstData, srcData, bytes)
        }
        return copy
    }
}
