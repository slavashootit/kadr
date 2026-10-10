import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Live input levels for the pre-recording check: microphone (AVCaptureSession) and system audio (ScreenCaptureKit).
@MainActor
final class AudioMeter: ObservableObject {
    @Published private(set) var mic: Float = 0       // 0...1
    @Published private(set) var system: Float = 0    // 0...1
    @Published private(set) var micError: String?
    @Published private(set) var systemError: String?

    private var session: AVCaptureSession?
    private var stream: SCStream?
    private let sink = MeterSink()
    private var decay: Timer?

    init() {
        sink.onLevel = { [weak self] kind, level in
            Task { @MainActor in self?.push(kind, level) }
        }
    }

    private func push(_ kind: MeterSink.Kind, _ level: Float) {
        switch kind {
        case .mic: mic = max(level, mic * 0.8)
        case .system: system = max(level, system * 0.8)
        }
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func microphone(id: String) -> AVCaptureDevice? {
        id.isEmpty ? AVCaptureDevice.default(for: .audio) : (AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .audio))
    }

    func start(micID: String?, system wantSystem: Bool) async {
        stop()
        decay = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.mic *= 0.85
                self.system *= 0.85
            }
        }
        if let micID { await startMic(id: micID) }
        if wantSystem { await startSystem() }
    }

    func stop() {
        decay?.invalidate()
        decay = nil
        if let s = session {
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        }
        session = nil
        if let st = stream { Task { try? await st.stopCapture() } }
        stream = nil
        mic = 0
        system = 0
    }

    private func startMic(id: String) async {
        micError = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            micError = "Немає доступу до мікрофона — дозволь у Параметрах → Приватність → Мікрофон"
            return
        }
        guard let device = Self.microphone(id: id) else { micError = "Мікрофон не знайдено"; return }
        do {
            let s = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { micError = "Мікрофон зайнятий"; return }
            s.addInput(input)
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
            out.setSampleBufferDelegate(sink, queue: sink.queue)
            guard s.canAddOutput(out) else { micError = "Не вдалося підключитись до мікрофона"; return }
            s.addOutput(out)
            session = s
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        } catch {
            micError = error.localizedDescription
        }
    }

    private func startSystem() async {
        systemError = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            let st = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try st.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try st.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await st.startCapture()
            stream = st
        } catch {
            systemError = "Системний звук недоступний: \(error.localizedDescription)"
        }
    }
}

final class MeterSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, @unchecked Sendable {
    enum Kind { case mic, system }
    let queue = DispatchQueue(label: "kadr.meter")
    var onLevel: ((Kind, Float) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onLevel?(.mic, AudioLevel.level(of: sampleBuffer))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onLevel?(.system, AudioLevel.level(of: sampleBuffer))
    }
}

enum AudioLevel {
    /// RMS of a PCM sample buffer mapped from -60...0 dBFS to 0...1.
    static func level(of sb: CMSampleBuffer) -> Float {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return 0 }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = asbd.mBitsPerChannel
        var sum: Double = 0
        var count = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData else { continue }
            let bytes = Int(buf.mDataByteSize)
            if isFloat && bits == 32 {
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(bytes / 4) { let v = Double(p[i]); sum += v * v }
                count += bytes / 4
            } else if bits == 16 {
                let p = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<(bytes / 2) { let v = Double(p[i]) / 32768; sum += v * v }
                count += bytes / 2
            } else if bits == 32 {
                let p = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<(bytes / 4) { let v = Double(p[i]) / 2_147_483_648; sum += v * v }
                count += bytes / 4
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / Double(count))
        let db = 20 * log10(max(rms, 1e-7))
        return Float(min(1, max(0, (db + 60) / 60)))
    }
}
