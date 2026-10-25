@preconcurrency import AVFoundation
import AudioToolbox
import Photos
import XCTest
@testable import ClearKeep

@MainActor
final class CompressionAdapterTests: XCTestCase {
    func testRealPhotosSavePersistsPlaceholderBeforeResourceAndRefetchesPlayableNewAsset() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Requires a dedicated simulator with Full Photos access granted to the test host. No permission prompt is requested by this test.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionPhotosFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("generated.mov")
        try await Self.makeVideo(url: url, portrait: false)
        let descriptor = try await VideoCompressionAdapter.describe(AVURLAsset(url: url))
        let expected = CompressionValidatedOutput(bytes: descriptor.bytes, duration: descriptor.duration, hasAudio: descriptor.hasAudio, displayWidth: descriptor.displayWidth, displayHeight: descriptor.displayHeight)
        let store = FileCompressionOperationStore(directory: folder.appendingPathComponent("mapping"))
        var operation = CompressionOperation(sourceID: "generated-test-source", profile: .balanced)
        operation.state = .saving
        let pending = operation
        try store.save(pending)
        let library = CompressionPhotoLibraryAdapter()
        let outputID = try await library.save(file: url) { placeholder in
            var durable = pending; durable.outputID = placeholder
            try store.save(durable)
        }
        XCTAssertEqual(try store.load(id: operation.id)?.outputID, outputID)
        let valid = try await library.verify(outputID: outputID, expected: expected)
        XCTAssertTrue(valid)
        XCTAssertNotNil(library.identity(sourceID: outputID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Deliberately retain only this generated fixture in the dedicated simulator;
        // the test never requests deletion permission or touches pre-existing media.
    }
    func testRealFullExportPreservesAudioAndValidatesNewFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("audio-original.mov")
        try await Self.makeVideo(url: sourceURL, portrait: false, audio: true)
        let adapter = VideoCompressionAdapter(directory: folder.appendingPathComponent("exports"), assetResolver: { _ in AVURLAsset(url: sourceURL) })
        let source = try await adapter.inspect(sourceID: "fixture")
        XCTAssertTrue(source.hasAudio)
        let id = UUID()
        let file = try await adapter.export(sourceID: "fixture", profile: .balanced, sampleDuration: nil, operationID: id, progress: { _ in })
        let validated = try await adapter.validate(file: file, source: source, expectedDuration: source.duration)
        XCTAssertTrue(validated.hasAudio)
        XCTAssertNotEqual(file.url, sourceURL)
        try adapter.cleanup(operationID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }
    func testRealExporterProducesPlayablePortraitSampleAndPreservesOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("original.mov")
        try await Self.makeVideo(url: sourceURL, portrait: true)
        let original = try Data(contentsOf: sourceURL)
        let adapter = VideoCompressionAdapter(directory: folder.appendingPathComponent("exports"), assetResolver: { _ in AVURLAsset(url: sourceURL) })
        let source = try await adapter.inspect(sourceID: "fixture")
        XCTAssertGreaterThan(source.displayHeight, source.displayWidth)
        XCTAssertTrue(source.bytesAreMeasured)
        XCTAssertFalse(source.hasAudio)
        let id = UUID()
        let output = try await adapter.export(sourceID: "fixture", profile: .smaller, sampleDuration: min(10, source.duration), operationID: id, progress: { _ in })
        let validated = try await adapter.validate(file: output, source: source, expectedDuration: source.duration)
        XCTAssertGreaterThan(validated.bytes, 0)
        XCTAssertEqual(validated.duration, source.duration, accuracy: 0.25)
        XCTAssertGreaterThan(validated.displayHeight, validated.displayWidth)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        try adapter.cleanup(operationID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRealValidatorRejectsWrongDurationWithoutRemovingSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("original.mov")
        try await Self.makeVideo(url: sourceURL, portrait: false)
        let adapter = VideoCompressionAdapter(directory: folder.appendingPathComponent("exports"), assetResolver: { _ in AVURLAsset(url: sourceURL) })
        let source = try await adapter.inspect(sourceID: "fixture")
        let file = CompressionExportedFile(url: sourceURL, bytes: source.bytes)
        do { _ = try await adapter.validate(file: file, source: source, expectedDuration: 100); XCTFail("Wrong duration must fail validation") }
        catch { XCTAssertEqual(error as? CompressionFailure, .invalidOutput) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    /// First-party generated moving colour frames, with no external fixture licence dependency.
    private static func makeVideo(url: URL, portrait: Bool, audio: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        if portrait { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        let audioInput = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]) : nil
        if let audioInput { writer.add(audioInput) }
        guard writer.startWriting() else { throw CompressionFailure.exportFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                attempts += 1
                guard attempts < 1_000, writer.status == .writing else { throw CompressionFailure.exportFailed }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CompressionFailure.exportFailed }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                for y in 0..<48 { for x in 0..<64 {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8((x * 3 + frame * 4) % 255)
                    bytes[offset + 1] = UInt8((y * 4 + frame * 2) % 255)
                    bytes[offset + 2] = UInt8(frame * 7); bytes[offset + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw CompressionFailure.exportFailed }
        }
        input.markAsFinished()
        if let audioInput {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true), let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { throw CompressionFailure.exportFailed }
            pcm.frameLength = 44_100
            if let samples = pcm.int16ChannelData?.pointee { for i in 0..<44_100 { samples[i] = Int16(sin(Double(i) * 2 * .pi * 440 / 44_100) * 1_000) } }
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, let description else { throw CompressionFailure.exportFailed }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 44_100, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
                  CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr else { throw CompressionFailure.exportFailed }
            CMSampleBufferSetDataReady(sample)
            var attempts = 0
            while !audioInput.isReadyForMoreMediaData { attempts += 1; guard attempts < 1_000 else { throw CompressionFailure.exportFailed }; try await Task.sleep(for: .milliseconds(2)) }
            guard audioInput.append(sample) else { throw CompressionFailure.exportFailed }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw CompressionFailure.exportFailed }
    }
}
