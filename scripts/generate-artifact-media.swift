import Foundation
import AVFoundation
import CoreVideo

// Synthetic, silent, 64x36 fixture. No camera, user media or remote input.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 64, AVVideoHeightKey: 36
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36
    ])
writer.add(input)
guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Fixture", code: 1) }
writer.startSession(atSourceTime: .zero)
for frame in 0..<6 {
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw writer.error ?? NSError(domain: "Fixture", code: 2) }
        Thread.sleep(forTimeInterval: 0.002)
    }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32ARGB,
        nil, &buffer) == kCVReturnSuccess, let buffer else { throw NSError(domain: "Fixture", code: 3) }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<36 {
        for x in 0..<64 {
            let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            base[i] = 255; base[i + 1] = UInt8(frame * 30); base[i + 2] = UInt8(x * 3); base[i + 3] = UInt8(y * 5)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
        throw writer.error ?? NSError(domain: "Fixture", code: 4)
    }
}
input.markAsFinished()
let completed = DispatchSemaphore(value: 0)
writer.finishWriting { completed.signal() }
guard completed.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
    throw writer.error ?? NSError(domain: "Fixture", code: 5)
}
print("synthetic video bytes=\((try Data(contentsOf: output)).count)")
