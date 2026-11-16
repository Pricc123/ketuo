import UIKit
import AVFoundation
import WebKit
import CoreImage

/// 原生高清车牌识别相机（iOS）
/// 用 AVCaptureSession 取 4K 视频帧（WebView 的 getUserMedia 最高只有 1080p），
/// 每 0.65 秒裁一帧中心区域转 JPEG 回传 H5 做 OCR，放大后依然清晰。
final class PlateScanController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    weak var webView: WKWebView?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "plate.scan.queue")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var device: AVCaptureDevice?
    private var maxZoom: CGFloat = 1
    private var curZoom: CGFloat = 1
    private var torchOn = false
    private var lastGrab = Date.distantPast
    private var frameCount = 0
    private var configured = false

    private let hint = UILabel()
    private let zoomSlider = UISlider()
    private let zoomLabel = UILabel()
    private let torchBtn = UIButton(type: .system)
    private let closeBtn = UIButton(type: .system)
    private let minusBtn = UIButton(type: .system)
    private let plusBtn = UIButton(type: .system)
    private let frameView = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
        webView?.evaluateJavaScript("window._onNativeClosed&&window._onNativeClosed()", completionHandler: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - UI

    private func buildUI() {
        let safeBottom = view.safeAreaInsets.bottom

        hint.text = "对准车牌，自动识别中..."
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textAlignment = .center
        hint.layer.shadowColor = UIColor.black.cgColor
        hint.layer.shadowOpacity = 0.8
        hint.layer.shadowRadius = 3
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        // 取景框
        frameView.layer.borderColor = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1).cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 16
        frameView.backgroundColor = .clear
        frameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameView)

        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let zoomRow = UIView()
        zoomRow.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(zoomRow)

        styleRound(minusBtn, title: "\u{2212}")
        styleRound(plusBtn, title: "+")
        minusBtn.addTarget(self, action: #selector(zoomOut), for: .touchUpInside)
        plusBtn.addTarget(self, action: #selector(zoomIn), for: .touchUpInside)
        minusBtn.translatesAutoresizingMaskIntoConstraints = false
        plusBtn.translatesAutoresizingMaskIntoConstraints = false
        zoomRow.addSubview(minusBtn)
        zoomRow.addSubview(plusBtn)

        zoomSlider.minimumValue = 1
        zoomSlider.maximumValue = 4
        zoomSlider.value = 1
        zoomSlider.tintColor = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
        zoomSlider.addTarget(self, action: #selector(zoomChanged), for: .valueChanged)
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomRow.addSubview(zoomSlider)

        zoomLabel.text = "1.0x"
        zoomLabel.textColor = .white
        zoomLabel.font = .systemFont(ofSize: 13, weight: .bold)
        zoomLabel.textAlignment = .right
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomRow.addSubview(zoomLabel)

        let btnRow = UIView()
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(btnRow)

        stylePill(torchBtn, title: "\u{1F526} 闪光灯")
        stylePill(closeBtn, title: "\u{2716} 关闭")
        torchBtn.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        closeBtn.addTarget(self, action: #selector(closeSelf), for: .touchUpInside)
        torchBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        btnRow.addSubview(torchBtn)
        btnRow.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.86),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: 0.34),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            zoomRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            zoomRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            zoomRow.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            zoomRow.heightAnchor.constraint(equalToConstant: 40),

            minusBtn.leadingAnchor.constraint(equalTo: zoomRow.leadingAnchor),
            minusBtn.centerYAnchor.constraint(equalTo: zoomRow.centerYAnchor),
            minusBtn.widthAnchor.constraint(equalToConstant: 40),
            minusBtn.heightAnchor.constraint(equalToConstant: 40),

            plusBtn.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -8),
            plusBtn.centerYAnchor.constraint(equalTo: zoomRow.centerYAnchor),
            plusBtn.widthAnchor.constraint(equalToConstant: 40),
            plusBtn.heightAnchor.constraint(equalToConstant: 40),

            zoomLabel.trailingAnchor.constraint(equalTo: zoomRow.trailingAnchor),
            zoomLabel.centerYAnchor.constraint(equalTo: zoomRow.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 48),

            zoomSlider.leadingAnchor.constraint(equalTo: minusBtn.trailingAnchor, constant: 8),
            zoomSlider.trailingAnchor.constraint(equalTo: plusBtn.leadingAnchor, constant: -8),
            zoomSlider.centerYAnchor.constraint(equalTo: zoomRow.centerYAnchor),

            btnRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            btnRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            btnRow.topAnchor.constraint(equalTo: zoomRow.bottomAnchor, constant: 12),
            btnRow.heightAnchor.constraint(equalToConstant: 46),
            btnRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -(12 + safeBottom * 0)),

            torchBtn.leadingAnchor.constraint(equalTo: btnRow.leadingAnchor),
            torchBtn.topAnchor.constraint(equalTo: btnRow.topAnchor),
            torchBtn.bottomAnchor.constraint(equalTo: btnRow.bottomAnchor),
            torchBtn.widthAnchor.constraint(equalTo: btnRow.widthAnchor, multiplier: 0.5, constant: -6),

            closeBtn.trailingAnchor.constraint(equalTo: btnRow.trailingAnchor),
            closeBtn.topAnchor.constraint(equalTo: btnRow.topAnchor),
            closeBtn.bottomAnchor.constraint(equalTo: btnRow.bottomAnchor),
            closeBtn.widthAnchor.constraint(equalTo: btnRow.widthAnchor, multiplier: 0.5, constant: -6),
        ])
    }

    private func styleRound(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        b.backgroundColor = UIColor(white: 1, alpha: 0.18)
        b.layer.cornerRadius = 20
    }

    private func stylePill(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.backgroundColor = UIColor(white: 1, alpha: 0.18)
        b.layer.cornerRadius = 23
    }

    // MARK: - Session

    private func configureSession() {
        guard !configured else { return }
        configured = true

        // 优先多摄虚拟设备：2x/3x 时自动切到长焦镜头（真光学变焦），放大不糊
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        let disc = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                    mediaType: .video,
                                                    position: .back)
        guard let dev = disc.devices.first
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            hint.text = "没有可用摄像头"
            return
        }
        device = dev
        maxZoom = min(max(dev.maxAvailableVideoZoomFactor, 1), 8)
        zoomSlider.maximumValue = Float(maxZoom)

        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            // 优先 4K：像素量是 1080p 的 4 倍，放大后依然清晰
            if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
            if session.canAddInput(input) {
                session.addInput(input)
            }
            // 4K 下用 YUV 420f 比 BGRA 省 2/3 带宽，避免掉帧和系统降级
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer

            try dev.lockForConfiguration()
            if dev.isGeometricDistortionCorrectionSupported {
                dev.isGeometricDistortionCorrectionEnabled = true
            }
            if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            dev.videoZoomFactor = 1
            dev.unlockForConfiguration()

            if session.sessionPreset == .hd4K3840x2160 {
                hint.text = "4K 原生 · 对准车牌自动识别中..."
            } else if session.sessionPreset == .hd1920x1080 {
                hint.text = "1080p 原生 · 对准车牌自动识别中..."
            }
        } catch {
            hint.text = "相机初始化失败"
        }
    }

    private func startSession() {
        guard configured else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func stopSession() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        if let d = device, d.hasTorch, d.torchMode == .on {
            try? d.lockForConfiguration()
            d.torchMode = .off
            try? d.unlockForConfiguration()
        }
    }

    // MARK: - 变焦 / 闪光灯

    private func applyZoom(_ z: CGFloat) {
        var v = z
        if v < 1 { v = 1 }
        if v > maxZoom { v = maxZoom }
        curZoom = v
        if let d = device {
            try? d.lockForConfiguration()
            d.videoZoomFactor = v
            try? d.unlockForConfiguration()
            refocusCenter(d)
        }
        zoomLabel.text = String(format: "%.1fx", v)
        if abs(zoomSlider.value - Float(v)) > 0.01 {
            zoomSlider.value = Float(v)
        }
    }

    /// 变焦后对画面中心重新对焦一次，再回连续对焦（车牌常在中心取景框）
    private func refocusCenter(_ d: AVCaptureDevice) {
        guard d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) else { return }
        try? d.lockForConfiguration()
        d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        d.focusMode = .autoFocus
        try? d.unlockForConfiguration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            try? d.lockForConfiguration()
            if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
            try? d.unlockForConfiguration()
        }
    }

    @objc private func zoomChanged() {
        applyZoom(CGFloat(zoomSlider.value))
    }

    @objc private func zoomIn() {
        applyZoom(curZoom + max(0.25, (maxZoom - 1) / 10))
    }

    @objc private func zoomOut() {
        applyZoom(curZoom - max(0.25, (maxZoom - 1) / 10))
    }

    @objc private func toggleTorch() {
        guard let d = device, d.hasTorch else { return }
        torchOn.toggle()
        try? d.lockForConfiguration()
        d.torchMode = torchOn ? .on : .off
        try? d.unlockForConfiguration()
        if torchOn {
            torchBtn.setTitle("\u{1F526} 已开", for: .normal)
            torchBtn.backgroundColor = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.9)
            torchBtn.setTitleColor(.black, for: .normal)
        } else {
            torchBtn.setTitle("\u{1F526} 闪光灯", for: .normal)
            torchBtn.backgroundColor = UIColor(white: 1, alpha: 0.18)
            torchBtn.setTitleColor(.white, for: .normal)
        }
    }

    @objc private func closeSelf() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - 取帧

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastGrab) >= 0.65 else { return }
        lastGrab = now
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var ci = CIImage(cvPixelBuffer: pb)
        // 后摄竖屏：sensor 输出需顺时针旋转 90°
        ci = ci.oriented(.right)
        let ext = ci.extent
        guard ext.width > 0, ext.height > 0 else { return }

        let cw = max(ext.width * 0.88, 480)
        let ch = max(ext.height * 0.36, 160)
        let sx = ext.minX + (ext.width - cw) / 2
        let sy = ext.minY + (ext.height - ch) / 2
        let cropRect = CGRect(x: sx, y: sy, width: cw, height: ch)
        var img = ci.cropped(to: cropRect)

        // 缩到 1600 宽，兼顾清晰度和传输体积
        let target: CGFloat = 1600
        if img.extent.width > target {
            let s = target / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = ciContext.createCGImage(img, from: img.extent) else { return }
        let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
        guard let data = ui.jpegData(compressionQuality: 0.85) else { return }
        let b64 = data.base64EncodedString()
        send(b64)
    }

    private func send(_ b64: String) {
        frameCount += 1
        let n = frameCount
        DispatchQueue.main.async { [weak self] in
            if n % 3 == 1 {
                self?.hint.text = "识别中... 第\(n)帧"
            }
        }
        guard let wv = webView else { return }
        let js = "window._onNativeFrame&&window._onNativeFrame('\(b64)')"
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
