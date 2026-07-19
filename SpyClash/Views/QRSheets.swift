import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins

struct RoomQRSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var copiedLink = false

    let room: GameRoom

    private var copy: QRInviteCopy {
        appState.language.qr
    }

    private var joinURL: URL {
        appState.client.roomJoinURL(code: room.code, target: appState.roomQRTarget)
    }

    private var inviteSubtitle: String {
        switch appState.roomQRTarget {
        case .web:
            localized(
                en: "Scan with any camera to join in a browser.",
                ru: "Отсканируй любой камерой, чтобы войти через браузер.",
                es: "Escanea con cualquier camara para entrar desde el navegador."
            )
        case .ios:
            localized(
                en: "Scan to open this room directly in SpyClash for iOS.",
                ru: "Отсканируй, чтобы открыть комнату прямо в SpyClash для iOS.",
                es: "Escanea para abrir la sala en SpyClash para iOS."
            )
        }
    }

    private var roomQRTargetBinding: Binding<RoomQRTarget> {
        Binding(
            get: { appState.roomQRTarget },
            set: { appState.roomQRTarget = $0 }
        )
    }

    private var shareInviteText: String {
        [
            "SpyClash room \(room.code.uppercased())",
            joinURL.absoluteString
        ].joined(separator: "\n")
    }

    var body: some View {
        ZStack {
            SpyBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    sheetHeader(
                        eyebrow: localized(en: "// ROOM INVITE", ru: "// ПРИГЛАШЕНИЕ", es: "// INVITACION"),
                        title: room.code.uppercased(),
                        subtitle: inviteSubtitle
                    )

                    RoomQRTargetToggle(
                        target: roomQRTargetBinding,
                        language: appState.language,
                        width: 140,
                        controlHeight: 36,
                        accessibilityIdentifier: "roomQR.targetToggle"
                    )

                    VStack(spacing: 16) {
                        QRCodeImageView(payload: joinURL.absoluteString, cornerRadius: 2)
                            .frame(width: 224, height: 224)
                            .spyQRCodeFrame(cut: 12, inset: 10)
                            .accessibilityIdentifier("roomQR.code")

                        Text(room.code.uppercased())
                            .font(SpyTheme.brandFont(size: 38))
                            .tracking(6)
                            .foregroundStyle(.white)

                        Text(joinURL.absoluteString)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(SpyTheme.dim)
                            .lineLimit(2)
                            .minimumScaleFactor(0.60)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(SpyTheme.card, in: CutCornerShape(cut: 12))
                    .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.stroke, lineWidth: 1))

                    ShareLink(item: shareInviteText) {
                        Label(copy.transmitInvite, systemImage: "square.and.arrow.up")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        HapticManager.shared.fire(.buttonPress)
                    })
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .accessibilityIdentifier("roomQR.share")

                    Button {
                        UIPasteboard.general.string = joinURL.absoluteString
                        copiedLink = true
                        HapticManager.shared.fire(.notification(.success))
                    } label: {
                        Label(
                            copiedLink
                                ? localized(en: "LINK COPIED", ru: "ССЫЛКА СКОПИРОВАНА", es: "ENLACE COPIADO")
                                : localized(en: "COPY LINK", ru: "КОПИРОВАТЬ ССЫЛКУ", es: "COPIAR ENLACE"),
                            systemImage: copiedLink ? "checkmark" : "link"
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline))
                    .accessibilityIdentifier("roomQR.copyLink")

                    Button {
                        dismiss()
                    } label: {
                        Label(copy.close, systemImage: "xmark")
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .accessibilityIdentifier("roomQR.close")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru:
            ru
        case .es:
            es
        default:
            en
        }
    }
}

struct RoomQRTargetToggle: View {
    @Binding var target: RoomQRTarget
    let language: AppLanguage
    var width: CGFloat = 76
    var controlHeight: CGFloat = 32
    var axis: Axis = .horizontal
    var accessibilityIdentifier = "onlineRoom.qrTargetToggle"

    var body: some View {
        Button {
            HapticManager.shared.fire(.tabSelection)
            withAnimation(.easeOut(duration: 0.18)) {
                target.toggle()
            }
        } label: {
            Group {
                if axis == .horizontal {
                    HStack(spacing: 2) {
                        segment("WEB", selected: target == .web)
                        segment("iOS", selected: target == .ios)
                    }
                } else {
                    VStack(spacing: 2) {
                        segment("WEB", selected: target == .web)
                        segment("iOS", selected: target == .ios)
                    }
                }
            }
            .padding(2)
            .frame(width: width, height: controlHeight)
            .background(Color.black.opacity(0.54), in: CutCornerShape(cut: 7))
            .overlay(
                CutCornerShape(cut: 7)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(CutCornerShape(cut: 7))
            .frame(width: max(width, 44), height: max(controlHeight, 44))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.96))
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(target == .web ? "WEB" : "iOS")
        .accessibilityHint(accessibilityHint)
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 7.5, weight: .black, design: .monospaced))
            .tracking(0.04)
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.30))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                selected ? SpyTheme.red.opacity(0.88) : Color.clear,
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
    }

    private var accessibilityLabel: String {
        switch language {
        case .ru:
            "Цель QR"
        case .es:
            "Destino del QR"
        default:
            "QR destination"
        }
    }

    private var accessibilityHint: String {
        switch (language, target) {
        case (.ru, .web):
            "Переключить на приложение iOS"
        case (.ru, .ios):
            "Переключить на веб-версию"
        case (.es, .web):
            "Cambiar a la app de iOS"
        case (.es, .ios):
            "Cambiar a la version web"
        case (_, .web):
            "Switch to the iOS app"
        case (_, .ios):
            "Switch to the web version"
        }
    }
}

struct QRCodeImageView: View {
    let payload: String
    var cornerRadius: CGFloat = 10
    @State private var render: QRCodeRender?

    var body: some View {
        ZStack {
            SpyTheme.dark

            if let render, render.payload == payload {
                Image(uiImage: render.image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("SpyClash room QR")
            } else {
                SpySpinner(size: 32, accent: SpyTheme.red)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: payload) {
            render = QRCodeRender(payload: payload, image: QRCodeFactory.image(from: payload))
        }
    }
}

private struct SpyQRCodeFrameModifier: ViewModifier {
    let cut: CGFloat
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .background(SpyTheme.card, in: CutCornerShape(cut: cut))
            .overlay(
                CutCornerShape(cut: cut)
                    .stroke(SpyTheme.strokeStrong, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                CornerStroke(color: SpyTheme.red.opacity(0.90))
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .overlay(alignment: .bottomTrailing) {
                CornerStroke(color: Color.white.opacity(0.34))
                    .rotationEffect(.degrees(180))
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .shadow(color: .black.opacity(0.42), radius: 12, y: 6)
    }
}

extension View {
    func spyQRCodeFrame(cut: CGFloat = 10, inset: CGFloat = 10) -> some View {
        modifier(SpyQRCodeFrameModifier(cut: cut, inset: inset))
    }
}

private struct QRCodeRender {
    let payload: String
    let image: UIImage
}

struct QRScannerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var permission: CameraPermission = .checking
    @State private var statusText: String?
    @State private var didScan = false
    @State private var lastInvalidScanAt = Date.distantPast
    @State private var lastInvalidPayload: String?
    @State private var joinTask: Task<Void, Never>?

    private var copy: QRInviteCopy {
        appState.language.qr
    }

    var body: some View {
        ZStack {
            SpyBackground()
            VStack(spacing: 18) {
                sheetHeader(eyebrow: copy.scanEyebrow, title: copy.scanTitle, subtitle: statusText ?? copy.alignRoomBeacon)

                switch permission {
                case .checking:
                    scannerState(icon: "viewfinder", title: copy.checkingCamera, detail: copy.cameraPreparing)
                case .denied:
                    scannerState(icon: "camera.fill", title: copy.cameraLocked, detail: copy.cameraLockedDetail)
                case .granted:
                    scannerFrame
                }

                Button {
                    dismiss()
                } label: {
                    Label(copy.cancel, systemImage: "xmark")
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .padding(.horizontal, 18)
            }
            .padding(.vertical, 24)
        }
        .task {
            await resolvePermission()
        }
        .onDisappear {
            joinTask?.cancel()
            joinTask = nil
        }
    }

    private var scannerFrame: some View {
        ZStack {
            QRScannerRepresentable(isScanningEnabled: !didScan) { payload in
                guard !didScan else { return }
                guard let code = SpyLinkParser.roomCodeIfPresent(from: payload) else {
                    let now = Date()
                    guard now.timeIntervalSince(lastInvalidScanAt) >= 1.5 else { return }
                    lastInvalidScanAt = now
                    statusText = copy.invalidCode
                    if lastInvalidPayload != payload {
                        lastInvalidPayload = payload
                        HapticManager.shared.fire(.notification(.warning))
                    }
                    return
                }

                didScan = true
                statusText = copy.joining(code)
                HapticManager.shared.fire(.buttonPress)
                joinTask?.cancel()
                joinTask = Task {
                    let joined = await appState.joinRoom(code: code)
                    guard !Task.isCancelled else { return }
                    statusText = joined ? copy.roomLinked : copy.roomNotFound
                    if joined {
                        do {
                            try await Task.sleep(for: .milliseconds(260))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        dismiss()
                    } else {
                        didScan = false
                    }
                    joinTask = nil
                }
            } onError: {
                statusText = localized(
                    en: "Camera could not start. Close the scanner and try again.",
                    ru: "Не удалось запустить камеру. Закрой сканер и попробуй снова.",
                    es: "No se pudo iniciar la camara. Cierra y vuelve a intentarlo."
                )
                HapticManager.shared.fire(.notification(.error))
            }
            .clipShape(CutCornerShape(cut: 18))
            .overlay(CutCornerShape(cut: 18).stroke(SpyTheme.red.opacity(0.9), lineWidth: 2))

            scannerReticle
        }
        .frame(height: 420)
        .padding(.horizontal, 18)
    }

    private var scannerReticle: some View {
        VStack {
            HStack {
                scanCorner
                Spacer()
                scanCorner.rotationEffect(.degrees(90))
            }
            Spacer()
            HStack {
                scanCorner.rotationEffect(.degrees(270))
                Spacer()
                scanCorner.rotationEffect(.degrees(180))
            }
        }
        .padding(22)
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru:
            ru
        case .es:
            es
        default:
            en
        }
    }

    private var scanCorner: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 34, y: 0))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 34))
        }
        .stroke(SpyTheme.red, lineWidth: 3)
        .frame(width: 34, height: 34)
        .shadow(color: SpyTheme.red, radius: 10)
    }

    private func scannerState(icon: String, title: String, detail: String) -> some View {
        SpyPanel {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                Text(title)
                    .font(.system(size: 22, weight: .black, design: .default))
                    .tracking(0.06)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                Text(detail)
                    .font(SpyTheme.micro)
                    .tracking(0.15)
                    .foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
        .padding(.horizontal, 18)
    }

    private func resolvePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }
    }
}

private enum CameraPermission {
    case checking
    case granted
    case denied
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let isScanningEnabled: Bool
    let onCode: (String) -> Void
    let onError: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isScanningEnabled: isScanningEnabled, onCode: onCode)
    }

    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(coordinator: context.coordinator, onError: onError)
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {
        context.coordinator.isScanningEnabled = isScanningEnabled
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        var isScanningEnabled: Bool

        init(isScanningEnabled: Bool, onCode: @escaping (String) -> Void) {
            self.isScanningEnabled = isScanningEnabled
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard isScanningEnabled,
                  let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = readableObject.stringValue else {
                return
            }

            isScanningEnabled = false
            onCode(stringValue)
        }
    }
}

private final class QRScannerSession: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.spyclash.qr-scanner.session", qos: .userInitiated)
    private let coordinator: QRScannerRepresentable.Coordinator
    private let onError: () -> Void
    private var isConfigured = false
    private var shouldRun = false

    init(coordinator: QRScannerRepresentable.Coordinator, onError: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onError = onError
    }

    var captureSession: AVCaptureSession {
        session
    }

    func configure() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.startIfReady()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }

        session.beginConfiguration()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else {
            session.commitConfiguration()
            reportConfigurationError()
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportConfigurationError()
            return
        }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()
        isConfigured = true
        startIfReady()
    }

    private func startIfReady() {
        guard shouldRun, isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    private func reportConfigurationError() {
        DispatchQueue.main.async { [onError] in
            onError()
        }
    }
}

private final class QRScannerController: UIViewController {
    private let scannerSession: QRScannerSession
    private let previewLayer = AVCaptureVideoPreviewLayer()

    init(coordinator: QRScannerRepresentable.Coordinator, onError: @escaping () -> Void) {
        scannerSession = QRScannerSession(coordinator: coordinator, onError: onError)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.session = scannerSession.captureSession
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        scannerSession.configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scannerSession.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scannerSession.stop()
    }
}

enum SpyLinkParser {
    static func roomCode(from payload: String) -> String {
        roomCodeIfPresent(from: payload) ?? payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber }
            .prefix(12)
            .uppercased()
    }

    static func roomCodeIfPresent(from payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed),
           let code = code(from: url) {
            return code
        }

        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[A-Za-z0-9]{4,12}$"#, options: .regularExpression) != nil else {
            return nil
        }

        return trimmed.uppercased()
    }

    private static func code(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let directCode = components.queryItems?.first(where: { ["join", "code", "room"].contains($0.name) })?.value {
            return normalizedCode(directCode)
        }

        if url.scheme == "spyclash" {
            if ["join", "room"].contains(url.host?.lowercased() ?? "") {
                let pathCode = url.pathComponents
                    .first { $0 != "/" && !$0.isEmpty }?
                    .filter { $0.isLetter || $0.isNumber }
                    .uppercased()
                if let pathCode, let normalized = normalizedCode(pathCode) {
                    return normalized
                }
            }

            if let host = url.host,
               !["auth", "join", "room"].contains(host.lowercased()),
               host.range(of: #"^[A-Za-z0-9]{4,12}$"#, options: .regularExpression) != nil {
                return normalizedCode(host)
            }
        }

        guard let fragment = url.fragment else {
            return nil
        }

        let query: String
        if fragment.hasPrefix("?") {
            query = String(fragment.dropFirst())
        } else if let queryStart = fragment.firstIndex(of: "?") {
            query = String(fragment[fragment.index(after: queryStart)...])
        } else {
            query = fragment
        }

        let fragmentCode = URLComponents(string: "https://spyclash.local?\(query)")?
            .queryItems?
            .first(where: { ["join", "code", "room"].contains($0.name) })?
            .value
        return fragmentCode.flatMap(normalizedCode)
    }

    private static func normalizedCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: #"^[A-Z0-9]{4,12}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return code
    }
}

enum QRCodeFactory {
    static func image(from text: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        let fallback = UIImage(systemName: "qrcode")?
            .withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
        let backgroundColor = UIColor(
            red: 10 / 255,
            green: 10 / 255,
            blue: 10 / 255,
            alpha: 1
        )

        guard let output = filter.outputImage?
            .applyingFilter(
                "CIFalseColor",
                parameters: [
                    "inputColor0": CIColor(color: .white),
                    "inputColor1": CIColor(color: backgroundColor)
                ]
            ) else {
            return fallback
        }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return fallback
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        // Four QR modules on every side; the module scale above is 14 px.
        let quietZone: CGFloat = 56
        let size = CGSize(
            width: CGFloat(cgImage.width) + (quietZone * 2),
            height: CGFloat(cgImage.height) + (quietZone * 2)
        )
        let innerRect = CGRect(
            x: quietZone,
            y: quietZone,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )
        let source = UIImage(cgImage: cgImage)

        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            backgroundColor.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            renderer.cgContext.interpolationQuality = .none
            source.draw(in: innerRect)
        }
    }
}

@ViewBuilder
func sheetHeader(eyebrow: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Text(eyebrow)
            .font(SpyTheme.micro)
            .tracking(0.12)
            .foregroundStyle(SpyTheme.dim)
            .lineLimit(2)
            .minimumScaleFactor(0.66)
            .allowsTightening(true)
            .multilineTextAlignment(.center)
        Text(title.uppercased())
            .font(.system(size: 32, weight: .black, design: .default))
            .tracking(title.count > 12 ? 0.02 : 0.08)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.52)
            .allowsTightening(true)
            .multilineTextAlignment(.center)
        Text(subtitle.uppercased())
            .font(SpyTheme.micro)
            .tracking(subtitle.count > 16 ? 0.02 : 0.08)
            .foregroundStyle(SpyTheme.red)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.58)
            .allowsTightening(true)
    }
    .padding(.horizontal, 20)
}
