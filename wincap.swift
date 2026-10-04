// wincap: record one window to a movie, by the process that owns it.
//
//   wincap PID OUT.mov [READY_FILE]
//
// Uses ScreenCaptureKit's single-window capture: only that window's own
// pixels are recorded, even if other windows cover it or it sits on
// another Space.  Nothing else on screen can end up in the video.
// Creates READY_FILE when the first frame arrives; stops on SIGTERM/SIGINT.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("wincap: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: wincap PID OUT.mov [READY_FILE]\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: args[2])
let readyPath = args.count > 3 ? args[3] : nil

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let pid: pid_t
    let outURL: URL
    let readyPath: String?
    var writer: AVAssetWriter!
    var input: AVAssetWriterInput!
    var stream: SCStream!
    var started = false
    let queue = DispatchQueue(label: "wincap.frames")

    init(pid: pid_t, outURL: URL, readyPath: String?) {
        self.pid = pid
        self.outURL = outURL
        self.readyPath = readyPath
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        // The process's main window: its largest titled one.  Skips tooltips,
        // child frames, and the untitled screen-sized window macOS can leave
        // behind after leaving fullscreen (it never updates).
        let windows = content.windows.filter {
            $0.owningApplication?.processID == self.pid && !($0.title ?? "").isEmpty
                && $0.frame.width > 200 && $0.frame.height > 200
        }
        guard let window = windows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { fail("no window found for process \(pid)") }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(filter.contentRect.width * scale) & ~1
        let height = Int(filter.contentRect.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Only complete frames; idle ones (nothing changed) carry no image.
        guard type == .screen, buffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete
        else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
            if let path = readyPath { FileManager.default.createFile(atPath: path, contents: nil) }
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    // The window going away (the demo quit) ends the capture too: keep
    // what was recorded.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await self.stop() }
    }

    var stopping = false
    @MainActor func stop() async {
        if stopping { return }
        stopping = true
        try? await stream.stopCapture()
        queue.sync {}
        guard started else { fail("no frames were captured") }
        input.markAsFinished()
        await writer.finishWriting()
        exit(writer.status == .completed ? 0 : 1)
    }
}

// ScreenCaptureKit needs a window-server connection, which a bare command
// line tool doesn't have until AppKit sets one up (no Dock icon, though).
NSApplication.shared.setActivationPolicy(.prohibited)

let recorder = Recorder(pid: pid, outURL: outURL, readyPath: readyPath)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { Task { await recorder.stop() } }
    source.resume()
    signalSources.append(source)
}
Task {
    do { try await recorder.start() } catch { fail(error.localizedDescription) }
}
dispatchMain()
