import UIKit
import AVFoundation
import WebKit
import CoreImage
import Vision

/// 原生高清车牌识别相机（iOS）
/// 用 AVCaptureSession 取 4K 视频帧（WebView 的 getUserMedia 最高只有 1080p），
/// 每 0.65 秒裁一帧中心区域转 JPEG 回传 H5 做 OCR，放大后依然清晰。
final class PlateScanController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {

    weak var webView: WKWebView?

    /// "plate" = 车牌识别；"qr" = 二维码/条码扫码
    var mode: String = "plate"

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var lastQR = ""
    private var lastQRTime = Date.distantPast
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "plate.scan.queue")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var device: AVCaptureDevice?
    private var maxZoom: CGFloat = 1
    private var curZoom: CGFloat = 1
    /// 打开相机时的默认倍率（3x 走长焦，车牌清晰度最好）
    private let defaultZoom: CGFloat = 3
    private var torchOn = false
    private var lastGrab = Date.distantPast
    /// 手动「高清拍照」请求：置 true 后下一帧走全图拍照流程
    private var wantShot = false
    private var frameCount = 0
    private var configured = false

    private let hint = UILabel()
    private let zoomSlider = UISlider()
    private let zoomLabel = UILabel()
    private let torchBtn = UIButton(type: .system)
    private let photoBtn = UIButton(type: .system)
    private let closeBtn = UIButton(type: .system)
    private let minusBtn = UIButton(type: .system)
    private let plusBtn = UIButton(type: .system)
    private let frameView = UIView()
    /// 10 秒识别倒计时（原生界面自己显示，不依赖 H5）
    private let countdownLabel = UILabel()
    private var countdownTimer: Timer?
    private var deadline: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
        startCountdown()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdown()
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

        hint.text = mode == "qr" ? "对准二维码自动识别..." : "对准车牌，自动识别中..."
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

        countdownLabel.text = ""
        countdownLabel.textColor = .white
        countdownLabel.font = .systemFont(ofSize: 13, weight: .bold)
        countdownLabel.textAlignment = .center
        countdownLabel.backgroundColor = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 0.92)
        countdownLabel.layer.cornerRadius = 12
        countdownLabel.clipsToBounds = true
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countdownLabel)

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
        stylePill(photoBtn, title: "\u{1F4F7} 高清拍照")
        stylePill(closeBtn, title: "\u{2716} 关闭")
        torchBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        photoBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        closeBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        photoBtn.backgroundColor = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 0.95)
        photoBtn.setTitleColor(.white, for: .normal)
        torchBtn.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        photoBtn.addTarget(self, action: #selector(takeShot), for: .touchUpInside)
        closeBtn.addTarget(self, action: #selector(closeSelf), for: .touchUpInside)
        torchBtn.translatesAutoresizingMaskIntoConstraints = false
        photoBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        btnRow.addSubview(torchBtn)
        btnRow.addSubview(photoBtn)
        btnRow.addSubview(closeBtn)

        // 双指缩放（原生相机不经过网页，需自己接手势）
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        view.addGestureRecognizer(pinch)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            countdownLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownLabel.bottomAnchor.constraint(equalTo: frameView.topAnchor, constant: -10),
            countdownLabel.widthAnchor.constraint(equalToConstant: 124),
            countdownLabel.heightAnchor.constraint(equalToConstant: 24),

            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: mode == "qr" ? 0.68 : 0.86),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: mode == "qr" ? 1.0 : 0.34),

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
            torchBtn.widthAnchor.constraint(equalTo: btnRow.widthAnchor, multiplier: 0.32, constant: -4),

            photoBtn.centerXAnchor.constraint(equalTo: btnRow.centerXAnchor),
            photoBtn.topAnchor.constraint(equalTo: btnRow.topAnchor),
            photoBtn.bottomAnchor.constraint(equalTo: btnRow.bottomAnchor),
            photoBtn.widthAnchor.constraint(equalTo: btnRow.widthAnchor, multiplier: 0.32, constant: -4),

            closeBtn.trailingAnchor.constraint(equalTo: btnRow.trailingAnchor),
            closeBtn.topAnchor.constraint(equalTo: btnRow.topAnchor),
            closeBtn.bottomAnchor.constraint(equalTo: btnRow.bottomAnchor),
            closeBtn.widthAnchor.constraint(equalTo: btnRow.widthAnchor, multiplier: 0.32, constant: -4),
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
        // 放开到设备硬件上限（iPhone Pro 系列多摄虚拟设备通常支持到 25x 左右）
        maxZoom = min(max(dev.maxAvailableVideoZoomFactor, 1), 25)
        zoomSlider.maximumValue = Float(maxZoom)
        zoomSlider.minimumValue = 1

        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            // 车牌优先 4K：像素量是 1080p 的 4 倍，放大后依然清晰
            // 核销二维码用 1080p 即可：帧率更高、对焦更快，二维码不需要 4K
            if mode == "qr" {
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                } else {
                    session.sessionPreset = .high
                }
            } else if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if mode == "qr" {
                // 扫码走系统级元数据识别，比网页 jsQR 快得多、暗光也稳
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    metadataOutput.metadataObjectTypes = [.qr, .ean13, .ean8, .code128, .code39]
                }
            } else {
                // 4K 下用 YUV 420f 比 BGRA 省 2/3 带宽，避免掉帧和系统降级
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
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

            // 车牌默认 3 倍：多摄虚拟设备会自动切到长焦镜头，真光学变焦
            // 核销二维码保持 1 倍：视野宽、对焦快，拉太近反而扫不出
            let startZoom: CGFloat = (mode == "qr") ? 1 : defaultZoom
            applyZoom(min(startZoom, maxZoom), refocus: false)

            if mode == "qr" {
                hint.text = "原生扫码 · 对准二维码自动识别"
            } else if session.sessionPreset == .hd4K3840x2160 {
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

    private func applyZoom(_ z: CGFloat, refocus: Bool = true) {
        var v = z
        if v < 1 { v = 1 }
        if v > maxZoom { v = maxZoom }
        curZoom = v
        if let d = device {
            try? d.lockForConfiguration()
            d.videoZoomFactor = v
            try? d.unlockForConfiguration()
            if refocus { refocusCenter(d) }
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

    private var pinchStartZoom: CGFloat = 1

    /// 双指缩放：过程中不重复对焦，松手后再对一次，避免画面抖动
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = curZoom
        case .changed:
            applyZoom(pinchStartZoom * g.scale, refocus: false)
        case .ended, .cancelled, .failed:
            applyZoom(pinchStartZoom * g.scale, refocus: true)
        default:
            break
        }
    }

    @objc private func zoomChanged() {
        applyZoom(CGFloat(zoomSlider.value))
    }

    @objc private func zoomIn() {
        applyZoom(curZoom + zoomStep())
    }

    @objc private func zoomOut() {
        applyZoom(curZoom - zoomStep())
    }

    /// 低倍细调（0.5），高倍粗调（按当前倍率 25% 递增），1x 到 25x 大约 10 步
    private func zoomStep() -> CGFloat {
        max(0.5, curZoom * 0.28)
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

    // MARK: - 10 秒倒计时

    private func startCountdown() {
        stopCountdown()
        deadline = Date().addingTimeInterval(10)
        updateCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
    }

    private func updateCountdown() {
        guard let d = deadline else { return }
        let left = d.timeIntervalSinceNow
        if left <= 0 {
            countdownLabel.text = "已超时"
            stopCountdown()
            DispatchQueue.main.async { [weak self] in
                self?.hint.text = "10 秒没认出来，请重试"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.dismiss(animated: true, completion: nil)
            }
            return
        }
        countdownLabel.text = String(format: "识别中 %ds", Int(ceil(left)))
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - 取帧

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        let shooting = wantShot
        if shooting {
            // 手动拍照：不受 0.6 秒节流限制，抓当前帧全图
            wantShot = false
            lastGrab = now
        } else {
            // 全走百度车牌识别：约 0.6 秒一帧；H5 侧识别成功后会自动关相机
            guard now.timeIntervalSince(lastGrab) >= 0.60 else { return }
            lastGrab = now
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var ci = CIImage(cvPixelBuffer: pb)
        // 后摄竖屏：sensor 输出需顺时针旋转 90°
        ci = ci.oriented(.right)
        let ext = ci.extent
        guard ext.width > 0, ext.height > 0 else { return }

        // 高清拍照：不裁剪，整幅缩到 1920 宽发出去，识别更准
        if shooting {
            var full = ci
            let tw: CGFloat = 1920
            if full.extent.width > tw {
                let s = tw / full.extent.width
                full = full.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            guard let fcg = ciContext.createCGImage(full, from: full.extent) else { return }
            let fui = UIImage(cgImage: fcg, scale: 1, orientation: .up)
            guard let fd = fui.jpegData(compressionQuality: 0.9) else { return }
            sendShot(fd.base64EncodedString())
            return
        }

        let cw = max(ext.width * 0.88, 480)
        let ch = max(ext.height * 0.36, 160)
        let sx = ext.minX + (ext.width - cw) / 2
        let sy = ext.minY + (ext.height - ch) / 2
        let cropRect = CGRect(x: sx, y: sy, width: cw, height: ch)
        var img = ci.cropped(to: cropRect)

        // 缩到 1200 宽，兼顾清晰度和传输体积
        let target: CGFloat = 1200
        if img.extent.width > target {
            let s = target / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = ciContext.createCGImage(img, from: img.extent) else { return }
        let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
        guard let data = ui.jpegData(compressionQuality: 0.85) else { return }
        // 先用手机自带 Vision 初筛：认出疑似车牌才把这一帧发百度复核；认不出不发，省额度
        gateAndVerify(ui, data: data)
    }

    // MARK: - 本地识别（Vision，零成本无限次）

    private var lastLocalPlate = ""
    private var lastLocalPlateTime = Date(timeIntervalSince1970: 0)

    /// 用 iOS 自带 Vision 做文字识别，命中车牌格式直接回调 H5
    private var visionBusy = false

    private func recognizeLocally(_ image: UIImage) {
        guard !visionBusy else { return }
        guard let cg = image.cgImage else { return }
        visionBusy = true
        let req = VNRecognizeTextRequest { [weak self] r, _ in
            guard let self = self else { return }
            self.visionBusy = false
            guard let obs = r.results as? [VNRecognizedTextObservation], !obs.isEmpty else { return }
            var found: String? = nil
            for o in obs {
                for cand in o.topCandidates(3) {
                    if let p = Self.extractPlate(cand.string) { found = p; break }
                }
                if found != nil { break }
            }
            self.reportVision(obs)
            guard let plate = found else {
                self.localMissCount += 1
                return
            }
            self.localMissCount = 0
            let now = Date()
            if plate == self.lastLocalPlate && now.timeIntervalSince(self.lastLocalPlateTime) < 3.0 { return }
            self.lastLocalPlate = plate
            self.lastLocalPlateTime = now
            self.sendPlate(plate)
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false
        let h = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try h.perform([req]) } catch { self?.visionBusy = false }
        }
    }

    // MARK: - 本地初筛 + 百度复核

    /// 百度复核请求在途：一次只放一帧出去，避免重复计费
    private var verifyInFlight = false
    /// 本地连续未命中帧数：攒够 missForce 帧就强制发一帧给百度兜底
    private var missSinceLastVerify = 0
    private let missForce = 15

    /// 先用手机自带 Vision 认一遍：认出车牌格式才把当前帧发百度复核；
    /// 认不出就不发（省额度）；连续 15 帧（约 9 秒）都认不出，强制发一帧兜底。
    private func gateAndVerify(_ image: UIImage, data: Data) {
        if verifyInFlight { return }
        guard !visionBusy, let cg = image.cgImage else { return }
        visionBusy = true
        let req = VNRecognizeTextRequest { [weak self] r, _ in
            guard let self = self else { return }
            self.visionBusy = false
            let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
            self.reportVision(obs)
            var found: String? = nil
            for o in obs {
                for cand in o.topCandidates(3) {
                    if let p = Self.extractPlate(cand.string) { found = p; break }
                }
                if found != nil { break }
            }
            if let p = found {
                self.missSinceLastVerify = 0
                self.lastLocalPlate = p
                self.lastLocalPlateTime = Date()
                self.fireVerify(data, hintText: "本地认出 \(p)，云端复核中...")
            } else {
                self.missSinceLastVerify += 1
                if self.missSinceLastVerify >= self.missForce {
                    self.missSinceLastVerify = 0
                    self.fireVerify(data, hintText: "云端兜底识别中...")
                }
            }
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false
        let h = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try h.perform([req]) } catch { self?.visionBusy = false }
        }
    }

    /// 把这一帧发给 H5，由 H5 调百度复核
    private func fireVerify(_ data: Data, hintText: String) {
        verifyInFlight = true
        DispatchQueue.main.async { [weak self] in
            self?.hint.text = hintText
        }
        send(data.base64EncodedString())
        // 百度回包后 H5 会关相机；万一没关，3 秒后解锁，避免卡死
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.verifyInFlight = false
        }
    }

    private var lastVisionReport = Date(timeIntervalSince1970: 0)

    /// 把 Vision 识别到的原始文本上报到服务器日志，便于校准车牌规则（3 秒最多一次）
    private func reportVision(_ obs: [VNRecognizedTextObservation]) {
        let now = Date()
        guard now.timeIntervalSince(lastVisionReport) >= 3.0 else { return }
        lastVisionReport = now
        var parts: [String] = []
        for o in obs.prefix(6) {
            if let t = o.topCandidates(1).first?.string, !t.isEmpty { parts.append(t) }
        }
        guard !parts.isEmpty else { return }
        let raw = parts.joined(separator: "|")
        guard let esc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://kt.pricc.fun/api/probe?native=vis&extra=\(esc)")
        else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    /// 从一段文本里提取合法车牌号
    static func extractPlate(_ raw: String) -> String? {
        var s = raw.uppercased()
        let drop = CharacterSet(charactersIn: " \u{00B7}\u{2022}.-\u{2014}_\u{2018}\u{2019},\u{FF0C}\u{3002}:\u{FF1A}\u{00A0}")
        s = s.filter { ch in !ch.unicodeScalars.contains(where: { drop.contains($0) }) }
        // 常见误识修正
        let fix: [(String, String)] = [
            ("\u{7CB5}", "\u{7CA4}"), ("\u{5967}", "\u{7CA4}"), ("\u{5965}", "\u{7CA4}"),
            ("\u{6CF8}", "\u{6CAA}")
        ]
        for (a, b) in fix { s = s.replacingOccurrences(of: a, with: b) }
        let pattern = "[\u{4EAC}\u{6D25}\u{6CAA}\u{6E1D}\u{5180}\u{8C6B}\u{4E91}\u{8FBD}\u{9ED1}\u{6E58}\u{7696}\u{9C81}\u{65B0}\u{82CF}\u{6D59}\u{8D63}\u{9102}\u{6842}\u{7518}\u{664B}\u{8499}\u{9655}\u{5409}\u{95FD}\u{8D35}\u{7CA4}\u{9752}\u{85CF}\u{5DDD}\u{5B81}\u{743C}][A-HJ-NP-Z][A-HJ-NP-Z0-9]{4,5}[A-HJ-NP-Z0-9\u{6302}\u{5B66}\u{8B66}\u{6E2F}\u{6FB3}]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    private func sendPlate(_ plate: String) {
        guard let wv = webView else { return }
        DispatchQueue.main.async { [weak self] in
            self?.hint.text = "\u{5DF2}\u{8BC6}\u{522B}\u{FF1A}\(plate)"
        }
        let esc = plate
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window._onNativePlate&&window._onNativePlate('\(esc)')"
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 扫码

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard mode == "qr" else { return }
        for o in metadataObjects {
            guard let code = o as? AVMetadataMachineReadableCodeObject,
                  let v = code.stringValue, !v.isEmpty else { continue }
            let now = Date()
            if v == lastQR && now.timeIntervalSince(lastQRTime) < 2.0 { return }
            lastQR = v
            lastQRTime = now
            sendQR(v)
            return
        }
    }

    private func sendQR(_ text: String) {
        guard let wv = webView else { return }
        DispatchQueue.main.async { [weak self] in
            self?.hint.text = "已识别，正在查询..."
        }
        let esc = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        let js = "window._onNativeQR&&window._onNativeQR('\(esc)')"
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private var lastNetSent = Date(timeIntervalSince1970: 0)
    /// 云端兜底：本地连续失败 2 秒后才用一次百度（车牌专用模型更准），一次进相机最多 3 次
    private var netFallbackEnabled = true
    private var netQuota = 3
    /// 本地识别连续未命中次数
    private var localMissCount = 0

    private func send(_ b64: String) {
        frameCount += 1
        let n = frameCount
        DispatchQueue.main.async { [weak self] in
            if n % 6 == 1 {
                self?.hint.text = "识别中... 第\(n)帧"
            }
        }
        guard let wv = webView else { return }
        let js = "window._onNativeFrame&&window._onNativeFrame('\(b64)')"
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 高清拍照：整幅图交给 H5 走一次识别（不受连续帧的 busy 限制）
    private func sendShot(_ b64: String) {
        DispatchQueue.main.async { [weak self] in
            self?.hint.text = "已拍照，识别中..."
        }
        guard let wv = webView else { return }
        let js = "window._onNativeShot&&window._onNativeShot('\(b64)')"
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc private func takeShot() {
        wantShot = true
        DispatchQueue.main.async { [weak self] in
            self?.hint.text = "拍照中..."
        }
    }
}
