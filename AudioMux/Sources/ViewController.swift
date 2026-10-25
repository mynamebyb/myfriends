import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

enum MuxMode: Int {
    case replace = 0
    case mix = 1
}

final class ViewController: UIViewController, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {

    private var videoURL: URL?
    private var audioURL: URL?

    private var mode: MuxMode = .replace
    private var audioOffset: Double = 0
    private var segStart: Double = 0
    private var segEnd: Double = 0
    private var fps: Int = 30
    private var resIndex: Int = 0       // 0原 1=720p 2=540p
    private var bitrate: Int = 5_000_000
    private var audioDuration: Double = 0

    private let videoBtn = UIButton(type: .system)
    private let audioBtn = UIButton(type: .system)
    private let segMode = UISegmentedControl(items: ["替换音轨", "混合音轨"])
    private let offsetSlider = UISlider()
    private let offsetLabel = UILabel()
    private let segStartSlider = UISlider()
    private let segStartLabel = UILabel()
    private let segEndSlider = UISlider()
    private let segEndLabel = UILabel()
    private let fpsSeg = UISegmentedControl(items: ["24fps", "30fps", "60fps"])
    private let resSeg = UISegmentedControl(items: ["原图", "720p", "540p"])
    private let brSeg = UISegmentedControl(items: ["2M", "5M", "8M"])
    private let exportBtn = UIButton(type: .system)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "音轨工具"
        setupUI()
    }

    private func setupUI() {
        videoBtn.setTitle("① 选择画面视频", for: .normal)
        videoBtn.addTarget(self, action: #selector(pickVideo), for: .touchUpInside)
        audioBtn.setTitle("② 选择声音源(视频/音频)", for: .normal)
        audioBtn.addTarget(self, action: #selector(pickAudio), for: .touchUpInside)
        segMode.selectedSegmentIndex = 0
        segMode.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        offsetSlider.minimumValue = 0; offsetSlider.maximumValue = 30; offsetSlider.value = 0
        offsetSlider.addTarget(self, action: #selector(offsetChanged), for: .valueChanged)
        segStartSlider.minimumValue = 0; segStartSlider.maximumValue = 60; segStartSlider.value = 0
        segStartSlider.addTarget(self, action: #selector(segStartChanged), for: .valueChanged)
        segEndSlider.minimumValue = 0; segEndSlider.maximumValue = 60; segEndSlider.value = 0
        segEndSlider.addTarget(self, action: #selector(segEndChanged), for: .valueChanged)

        fpsSeg.selectedSegmentIndex = 1
        fpsSeg.addTarget(self, action: #selector(paramChanged), for: .valueChanged)
        resSeg.selectedSegmentIndex = 0
        resSeg.addTarget(self, action: #selector(paramChanged), for: .valueChanged)
        brSeg.selectedSegmentIndex = 1
        brSeg.addTarget(self, action: #selector(paramChanged), for: .valueChanged)

        exportBtn.setTitle("开始合成", for: .normal)
        exportBtn.tintColor = .systemBlue
        exportBtn.addTarget(self, action: #selector(startExport), for: .touchUpInside)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .left
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 13)
        refreshLabels()
        refreshParams()

        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sv)

        let stack = UIStackView(arrangedSubviews: [
            videoBtn, audioBtn, segMode,
            makeRow(title: "音轨偏移(秒,靠后插):", slider: offsetSlider, label: offsetLabel),
            makeRow(title: "音轨起始(秒):", slider: segStartSlider, label: segStartLabel),
            makeRow(title: "音轨结束(秒):", slider: segEndSlider, label: segEndLabel),
            makeLabel("导出帧率"), fpsSeg,
            makeLabel("分辨率"), resSeg,
            makeLabel("码率"), brSeg,
            exportBtn, statusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(stack)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            sv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: sv.widthAnchor, constant: -48)
        ])
    }

    private func makeLabel(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        return l
    }

    private func makeRow(title: String, slider: UISlider, label: UILabel) -> UIStackView {
        let l = makeLabel(title)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let st = UIStackView(arrangedSubviews: [l, slider, label])
        st.axis = .vertical
        st.spacing = 2
        return st
    }

    @objc private func pickVideo() {
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos
        cfg.selectionLimit = 1
        let p = PHPickerViewController(configuration: cfg)
        p.delegate = self
        present(p, animated: true)
    }

    @objc private func pickAudio() {
        let dc = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .audio])
        dc.delegate = self
        dc.allowsMultipleSelection = false
        present(dc, animated: true)
    }

    @objc private func modeChanged() { mode = MuxMode(rawValue: segMode.selectedSegmentIndex) ?? .replace }
    @objc private func offsetChanged() { audioOffset = Double(offsetSlider.value); refreshLabels() }
    @objc private func segStartChanged() { segStart = Double(segStartSlider.value); refreshLabels() }
    @objc private func segEndChanged() { segEnd = Double(segEndSlider.value); refreshLabels() }
    @objc private func paramChanged() {
        let fp = [24, 30, 60]; fps = fp[min(max(fpsSeg.selectedSegmentIndex, 0), 2)]
        resIndex = min(max(resSeg.selectedSegmentIndex, 0), 2)
        let brs = [2_000_000, 5_000_000, 8_000_000]; bitrate = brs[min(max(brSeg.selectedSegmentIndex, 0), 2)]
        refreshParams()
    }

    private func refreshLabels() {
        offsetLabel.text = String(format: "%.1f", audioOffset)
        segStartLabel.text = String(format: "%.1f", segStart)
        segEndLabel.text = String(format: "%.1f", segEnd)
    }
    private func refreshParams() {
        let fp = [24, 30, 60]; let brs = [2_000_000, 5_000_000, 8_000_000]
        statusLabel.text = "参数：\(fp[min(fpsSeg.selectedSegmentIndex,2)])fps / 分辨率\(["原图","720p","540p"][resIndex]) / \(brs[min(brSeg.selectedSegmentIndex,2)]/1_000_000)Mbps\n选画面视频+声音源后开始合成。画面来自①，声音来自②。"
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let item = results.first?.itemProvider else { return }
        guard item.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            statusLabel.text = "选的不是视频"; return
        }
        item.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { return }
            let dst = Self.tmpCopy(of: url, ext: "mov")
            DispatchQueue.main.async {
                self?.videoURL = dst
                self?.statusLabel.text = "画面视频已选：\(dst.lastPathComponent)"
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let dst = Self.tmpCopy(of: url, ext: ext)
        audioURL = dst
        let a = AVURLAsset(url: dst)
        audioDuration = CMTimeGetSeconds(a.duration)
        segEndSlider.maximumValue = Float(audioDuration > 0 ? audioDuration : 60)
        segEndSlider.value = Float(audioDuration > 0 ? audioDuration : 0)
        segStartSlider.maximumValue = segEndSlider.maximumValue
        segEnd = audioDuration
        refreshLabels()
        statusLabel.text = "声音源已选：\(dst.lastPathComponent)，时长\(String(format: "%.1f", audioDuration))s"
    }

    private static func tmpCopy(of src: URL, ext: String) -> URL {
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("src_\(Int(Date().timeIntervalSince1970)).\(ext)")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    @objc private func startExport() {
        guard let videoURL else { statusLabel.text = "先选画面视频"; return }
        guard let audioURL else { statusLabel.text = "先选声音源"; return }
        guard segEnd > segStart else { statusLabel.text = "音轨结束需大于起始"; return }
        exportBtn.isEnabled = false
        statusLabel.text = "合成中…"
        Muxer.mux(videoURL: videoURL, audioURL: audioURL, mode: mode,
                  offset: audioOffset, segStart: segStart, segEnd: segEnd,
                  fps: fps, resIndex: resIndex, bitrate: bitrate) { [weak self] out, error in
            DispatchQueue.main.async {
                self?.exportBtn.isEnabled = true
                if let error {
                    self?.statusLabel.text = "失败：\(error.localizedDescription)"
                    return
                }
                self?.statusLabel.text = "完成，保存中…"
                self?.saveToPhotos(out)
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization { [weak self] st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { self?.statusLabel.text = "没有相册权限" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, err in
                DispatchQueue.main.async {
                    self?.statusLabel.text = ok ? "已保存到相册 ✅" : "保存失败 \(err?.localizedDescription ?? "")"
                    let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    self?.present(ac, animated: true)
                }
            }
        }
    }
}

// MARK: - 合成逻辑（AVAssetReader + AVAssetWriter 重编码，支持 fps/分辨率/码率）

enum Muxer {
    static func mux(videoURL: URL, audioURL: URL, mode: MuxMode,
                    offset: Double, segStart: Double, segEnd: Double,
                    fps: Int, resIndex: Int, bitrate: Int,
                    completion: @escaping (URL?, Error?) -> Void) {

        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        let aAsset = AVURLAsset(url: audioURL)

        do {
            guard let srcV = vAsset.tracks(withMediaType: .video).first,
                  let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw err("画面视频无视频轨")
            }
            let vDur = vAsset.duration
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: srcV, at: .zero)

            if mode == .mix, let srcA = vAsset.tracks(withMediaType: .audio).first,
               let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: srcA, at: .zero)
            }

            guard let srcA = aAsset.tracks(withMediaType: .audio).first,
                  let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw err("声音源无音频轨")
            }
            let ts = CMTimeScale(600)
            let segStartT = CMTime(seconds: max(segStart, 0), preferredTimescale: ts)
            let segEndT = CMTime(seconds: min(segEnd, CMTimeGetSeconds(aAsset.duration)), preferredTimescale: ts)
            let segLen = CMTimeSubtract(segEndT, segStartT)
            guard segLen.seconds > 0 else { throw err("音轨分段为空") }
            let at = CMTime(seconds: max(offset, 0), preferredTimescale: ts)
            try aTrack.insertTimeRange(CMTimeRange(start: segStartT, duration: segLen), of: srcA, at: at)
        } catch {
            completion(nil, error)
            return
        }

        let natural = vAsset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
        var target = natural
        switch resIndex {
        case 1:
            if natural.width > 1280 { let s = 1280 / natural.width; target = CGSize(width: 1280, height: (natural.height * s / 2) * 2) }
        case 2:
            let w = min(720, natural.width)
            let s = w / max(natural.width, 1)
            target = CGSize(width: w, height: (natural.height * s / 2) * 2)
        default: break
        }
        if target.width.truncatingRemainder(dividingBy: 2) != 0 { target.width -= 1 }
        if target.height.truncatingRemainder(dividingBy: 2) != 0 { target.height -= 1 }
        let frameDuration = CMTime(value: 1, timescale: Int32(fps))

        let vc = AVMutableVideoComposition(asset: comp) { request in
            let src = request.sourceImage.clampedToExtent()
            let s = min(target.width / src.extent.width, target.height / src.extent.height)
            let out = src.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .cropped(to: CGRect(x: 0, y: 0, width: target.width, height: target.height))
            request.finish(with: out, context: nil)
        }
        vc.renderSize = target
        vc.frameDuration = frameDuration

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mux_\(Int(Date().timeIntervalSince1970)).mp4")
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else {
            completion(nil, err("无法创建 writer")); return
        }

        let wv = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ])
        wv.expectsMediaDataInRealTime = false
        let wa = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ])
        wa.expectsMediaDataInRealTime = false
        guard writer.canAdd(wv), writer.canAdd(wa) else { completion(nil, err("无法添加轨")); return }
        writer.add(wv); writer.add(wa)

        guard let reader = try? AVAssetReader(asset: comp) else { completion(nil, err("无法创建 reader")); return }
        let rv = AVAssetReaderVideoCompositionOutput(
            videoTracks: comp.tracks(withMediaType: .video),
            videoSettings: [(kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA],
            videoComposition: vc)
        let ra = AVAssetReaderTrackOutput(track: comp.tracks(withMediaType: .audio).first!,
                                          outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(rv), reader.canAdd(ra) else { completion(nil, err("reader 无法加轨")); return }
        reader.add(rv); reader.add(ra)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()

        let queue = DispatchQueue(label: "mux.pump")
        func pumpVideo() {
            while wv.isReadyForMoreMediaData {
                guard let sb = rv.copyNextSampleBuffer() else { wv.markAsFinished(); return }
                wv.append(sb)
            }
        }
        func pumpAudio() {
            while wa.isReadyForMoreMediaData {
                guard let sb = ra.copyNextSampleBuffer() else { wa.markAsFinished(); return }
                wa.append(sb)
            }
        }
        wv.requestMediaDataWhenReady(on: queue, using: pumpVideo)
        wa.requestMediaDataWhenReady(on: queue, using: pumpAudio)

        DispatchQueue.global().async {
            while writer.status == .writing {
                if reader.status == .completed { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            writer.finishWriting {
                if writer.status == .completed {
                    completion(out, nil)
                } else {
                    completion(nil, writer.error ?? err("导出失败 status=\(writer.status.rawValue)"))
                }
            }
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "AudioMux", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
