import SceneKit
import SwiftUI

/// A physical, two-sided card. Only public profile fields are included in either texture.
struct PlayerSpyCard3DView: View {
    let profile: PublicSpyProfile
    let language: AppLanguage
    let reduceMotion: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var rotationRequest = 0
    @State private var resetRequest = 0

    private var copy: PlayerSpyCard3DCopy { PlayerSpyCard3DCopy(language: language) }

    var body: some View {
        VStack(spacing: 0) {
            PlayerSpyCardScene(
                profile: profile,
                language: language,
                reduceMotion: reduceMotion,
                isActive: scenePhase == .active,
                rotationRequest: rotationRequest,
                resetRequest: resetRequest
            )
            .aspectRatio(1.15, contentMode: .fit)
            .accessibilityHidden(true)

            Label(copy.dragHint, systemImage: "hand.draw")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.48))
                .padding(.top, 2)
                .accessibilityHidden(true)

            Text(copy.resetHint)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.34))
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CommunitySpyCardCopy(language: language).accessibilityLabel(for: profile))
        .accessibilityHint(copy.accessibilityHint)
        .accessibilityAction(named: Text(copy.rotate)) { rotationRequest &+= 1 }
        .accessibilityAction(named: Text(copy.showFront)) { resetRequest &+= 1 }
        .accessibilityIdentifier("lobby.playerCard3D")
    }
}

private struct PlayerSpyCardScene: UIViewRepresentable {
    let profile: PublicSpyProfile
    let language: AppLanguage
    let reduceMotion: Bool
    let isActive: Bool
    let rotationRequest: Int
    let resetRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        // Scene mutations request a frame. There is no permanent rendering or idle spin.
        view.rendersContinuously = false
        view.isPlaying = false
        view.isAccessibilityElement = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            profile: profile,
            language: language,
            reduceMotion: reduceMotion,
            isActive: isActive,
            rotationRequest: rotationRequest,
            resetRequest: resetRequest
        )
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.detach()
        view.scene = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var view: SCNView?
        private let card = SCNNode()
        private let frontMaterial = SCNMaterial()
        private let backMaterial = SCNMaterial()
        private var panGesture: UIPanGestureRecognizer?
        private var resetGesture: UITapGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var displayLinkTarget: DisplayLinkTarget?
        private var lastProfile: PublicSpyProfile?
        private var lastLanguage: AppLanguage?
        private var reduceMotion = false
        private var isActive = true
        private var rotationRequest = 0
        private var resetRequest = 0
        private var pitch: Float = 0.04
        private var yaw: Float = -0.08
        private var pitchVelocity: Float = 0
        private var yawVelocity: Float = 0
        private var lastFrameTime: CFTimeInterval = 0
        private var motionStartTime: CFTimeInterval = 0
        private var turn: Turn?

        private struct Turn {
            let fromPitch: Float
            let fromYaw: Float
            let toPitch: Float
            let toYaw: Float
        }

        func attach(to view: SCNView) {
            self.view = view
            let scene = SCNScene()
            scene.background.contents = UIColor.clear

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.projectionDirection = .horizontal
            camera.camera?.fieldOfView = 38
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = 30
            camera.position = SCNVector3(0, 0, 6.7)
            scene.rootNode.addChildNode(camera)
            view.pointOfView = camera

            let geometry = SCNBox(width: 3.6, height: 2.4, length: 0.075, chamferRadius: 0.035)
            geometry.chamferSegmentCount = 4
            let edge = SCNMaterial()
            edge.lightingModel = .physicallyBased
            edge.diffuse.contents = UIColor(red: 0.31, green: 0.12, blue: 0.13, alpha: 1)
            edge.metalness.contents = 0.82
            edge.roughness.contents = 0.29
            edge.emission.contents = UIColor(red: 0.09, green: 0.012, blue: 0.016, alpha: 1)

            for material in [frontMaterial, backMaterial] {
                material.lightingModel = .physicallyBased
                material.metalness.contents = 0.12
                material.roughness.contents = 0.44
                material.emission.intensity = 0.38
                material.diffuse.magnificationFilter = .linear
                material.diffuse.minificationFilter = .linear
                material.diffuse.mipFilter = .linear
                material.isDoubleSided = false
            }
            // SCNBox face order is front, right, back, left, top, bottom.
            geometry.materials = [frontMaterial, edge, backMaterial, edge, edge, edge]
            card.geometry = geometry
            card.castsShadow = false
            scene.rootNode.addChildNode(card)

            addLight(to: scene, type: .ambient, color: .white, intensity: 470, position: SCNVector3Zero)
            addLight(to: scene, type: .omni, color: .white, intensity: 710, position: SCNVector3(-3, 4, 5))
            addLight(
                to: scene,
                type: .omni,
                color: UIColor(red: 1, green: 0.22, blue: 0.24, alpha: 1),
                intensity: 380,
                position: SCNVector3(4, -1, -2)
            )
            view.scene = scene
            applyOrientation()

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            panGesture = pan

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetOrientation(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
            resetGesture = doubleTap
        }

        func update(
            profile: PublicSpyProfile,
            language: AppLanguage,
            reduceMotion: Bool,
            isActive: Bool,
            rotationRequest: Int,
            resetRequest: Int
        ) {
            self.reduceMotion = reduceMotion
            self.isActive = isActive
            if reduceMotion || !isActive { stopMotion() }
            view?.isUserInteractionEnabled = isActive

            // Texture rendering happens only when public content or its language changes.
            if isActive && (lastProfile != profile || lastLanguage != language) {
                let front = renderTexture(
                    CommunitySpyCard(profile: profile, language: language)
                        .frame(width: 360, height: 240)
                        .background(Color(red: 0.035, green: 0.035, blue: 0.040))
                )
                let back = renderTexture(PlayerSpyCardBack(profile: profile, language: language))
                // A failed/background render must not poison the cache. Scene activation
                // triggers another update, so deferred textures get another opportunity.
                if let front, let back {
                    lastProfile = profile
                    lastLanguage = language
                    frontMaterial.diffuse.contents = front
                    frontMaterial.emission.contents = front
                    backMaterial.diffuse.contents = back
                    backMaterial.emission.contents = back
                    view?.setNeedsDisplay()
                }
            }

            if self.resetRequest != resetRequest {
                self.resetRequest = resetRequest
                turnTo(pitch: 0, yaw: nearestFrontYaw)
            } else if self.rotationRequest != rotationRequest {
                self.rotationRequest = rotationRequest
                turnTo(pitch: 0, yaw: yaw + .pi)
            }
        }

        func detach() {
            stopMotion()
            if let panGesture { view?.removeGestureRecognizer(panGesture) }
            if let resetGesture { view?.removeGestureRecognizer(resetGesture) }
            panGesture = nil
            resetGesture = nil
            view?.isPlaying = false
            view?.rendersContinuously = false
            view = nil
        }

        private var nearestFrontYaw: Float {
            (yaw / (2 * .pi)).rounded() * (2 * .pi)
        }

        @objc private func resetOrientation(_ gesture: UITapGestureRecognizer) {
            guard isActive, gesture.state == .ended else { return }
            turnTo(pitch: 0, yaw: nearestFrontYaw)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard isActive, let view else { return }
            let scaleX = Float(2 * Double.pi / max(view.bounds.width, 1))
            let scaleY = Float(2 * Double.pi / max(view.bounds.height, 1))
            switch gesture.state {
            case .began:
                stopMotion()
            case .changed:
                let translation = gesture.translation(in: view)
                yaw += Float(translation.x) * scaleX
                pitch += Float(translation.y) * scaleY
                gesture.setTranslation(.zero, in: view)
                applyOrientation()
            case .ended:
                guard !reduceMotion else { return }
                let velocity = gesture.velocity(in: view)
                yawVelocity = min(max(Float(velocity.x) * scaleX, -8), 8)
                pitchVelocity = min(max(Float(velocity.y) * scaleY, -8), 8)
                if abs(yawVelocity) + abs(pitchVelocity) > 0.08 { startMotion() }
            case .cancelled, .failed:
                stopMotion()
            default:
                break
            }
        }

        private func turnTo(pitch targetPitch: Float, yaw targetYaw: Float) {
            stopMotion()
            if reduceMotion || !isActive {
                pitch = targetPitch
                yaw = targetYaw
                applyOrientation()
            } else {
                turn = Turn(fromPitch: pitch, fromYaw: yaw, toPitch: targetPitch, toYaw: targetYaw)
                startMotion()
            }
        }

        private func startMotion() {
            guard displayLink == nil else { return }
            lastFrameTime = 0
            motionStartTime = 0
            let target = DisplayLinkTarget(owner: self)
            displayLinkTarget = target
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        private func stopMotion() {
            displayLink?.invalidate()
            displayLink = nil
            displayLinkTarget = nil
            pitchVelocity = 0
            yawVelocity = 0
            turn = nil
        }

        fileprivate func step(_ link: CADisplayLink) {
            guard isActive, !reduceMotion else {
                stopMotion()
                return
            }
            if motionStartTime == 0 { motionStartTime = link.timestamp }
            let elapsed = link.timestamp - motionStartTime
            let delta = Float(min(max(link.timestamp - lastFrameTime, 0), 1.0 / 30.0))
            lastFrameTime = link.timestamp

            if let turn {
                let progress = Float(min(elapsed / 0.42, 1))
                let eased = 1 - pow(1 - progress, 3)
                pitch = turn.fromPitch + (turn.toPitch - turn.fromPitch) * eased
                yaw = turn.fromYaw + (turn.toYaw - turn.fromYaw) * eased
                applyOrientation()
                if progress >= 1 { stopMotion() }
            } else {
                pitch += pitchVelocity * delta
                yaw += yawVelocity * delta
                let damping = exp(-5.5 * delta)
                pitchVelocity *= damping
                yawVelocity *= damping
                applyOrientation()
                if elapsed >= 1.15 || abs(pitchVelocity) + abs(yawVelocity) < 0.055 {
                    stopMotion()
                }
            }
        }

        private func applyOrientation() {
            // Keep repeated full revolutions numerically stable without restricting rotation.
            if turn == nil {
                pitch.formTruncatingRemainder(dividingBy: 2 * .pi)
                yaw.formTruncatingRemainder(dividingBy: 2 * .pi)
            }
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            card.eulerAngles = SCNVector3(pitch, yaw, 0)
            SCNTransaction.commit()
            view?.setNeedsDisplay()
        }

        private func renderTexture<Content: View>(_ content: Content) -> UIImage? {
            let renderer = ImageRenderer(
                content: content
                    .frame(width: 360, height: 240)
                    .environment(\.colorScheme, .dark)
                    .environment(\.displayScale, 3)
            )
            renderer.proposedSize = ProposedViewSize(width: 360, height: 240)
            renderer.scale = 3
            renderer.isOpaque = true
            return renderer.uiImage
        }

        private func addLight(
            to scene: SCNScene,
            type: SCNLight.LightType,
            color: UIColor,
            intensity: CGFloat,
            position: SCNVector3
        ) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.color = color
            node.light?.intensity = intensity
            node.position = position
            scene.rootNode.addChildNode(node)
        }
    }

    /// CADisplayLink retains its target, so the target must not retain the coordinator.
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: Coordinator?

        init(owner: Coordinator) { self.owner = owner }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.step(link)
        }
    }
}

private struct PlayerSpyCardBack: View {
    let profile: PublicSpyProfile
    let language: AppLanguage

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.025, blue: 0.03)
            LinearGradient(
                colors: [SpyTheme.red.opacity(0.17), .clear, SpyTheme.red.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                var lines = Path()
                for x in stride(from: 0.0, through: size.width, by: 18) {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 18) {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(lines, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
            }

            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("SPY").foregroundStyle(SpyTheme.red)
                    Text("CLASH").foregroundStyle(.white)
                }
                .font(SpyTheme.brandFont(size: 30))
                .tracking(5)

                HStack(spacing: 12) {
                    Rectangle().fill(SpyTheme.red.opacity(0.4)).frame(height: 1)
                    SpyBrandMark().frame(width: 32, height: 42)
                    Rectangle().fill(SpyTheme.red.opacity(0.4)).frame(height: 1)
                }
                .padding(.horizontal, 48)

                Text(profile.displayName.uppercased())
                    .font(SpyTheme.brandFont(size: 22))
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white.opacity(0.9))

                Text("SPYID • \(profile.spyID)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(PlayerSpyCard3DCopy(language: language).publicDossier)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(SpyTheme.red.opacity(0.85))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)

            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                .padding(8)
        }
        .frame(width: 360, height: 240)
    }
}

private struct PlayerSpyCard3DCopy {
    let language: AppLanguage

    var dragHint: String {
        switch language {
        case .en: "DRAG TO ROTATE"
        case .es: "ARRASTRA PARA GIRAR"
        case .ru: "ВРАЩАЙТЕ КАРТОЧКУ ПАЛЬЦЕМ"
        case .uk: "ОБЕРТАЙТЕ КАРТКУ ПАЛЬЦЕМ"
        }
    }

    var accessibilityHint: String {
        switch language {
        case .en: "All profile details are read above. Actions can turn the card or show its front."
        case .es: "Todos los datos del perfil se leen arriba. Las acciones giran la tarjeta o muestran el frente."
        case .ru: "Все данные профиля озвучены. Действия позволяют перевернуть карточку или показать лицевую сторону."
        case .uk: "Усі дані профілю озвучено. Дії дозволяють перевернути картку або показати лицьовий бік."
        }
    }

    var resetHint: String {
        switch language {
        case .en: "DOUBLE-TAP TO SHOW THE FRONT"
        case .es: "TOCA DOS VECES PARA VER EL FRENTE"
        case .ru: "ДВОЙНОЙ ТАП — ЛИЦЕВАЯ СТОРОНА"
        case .uk: "ПОДВІЙНИЙ ДОТИК — ЛИЦЬОВИЙ БІК"
        }
    }

    var rotate: String {
        switch language {
        case .en: "Turn card over"
        case .es: "Dar la vuelta a la tarjeta"
        case .ru: "Перевернуть карточку"
        case .uk: "Перевернути картку"
        }
    }

    var showFront: String {
        switch language {
        case .en: "Show card front"
        case .es: "Mostrar el frente"
        case .ru: "Показать лицевую сторону"
        case .uk: "Показати лицьовий бік"
        }
    }

    var publicDossier: String {
        switch language {
        case .en: "PUBLIC AGENT DOSSIER"
        case .es: "EXPEDIENTE PÚBLICO DEL AGENTE"
        case .ru: "ПУБЛИЧНОЕ ДОСЬЕ ОПЕРАТИВНИКА"
        case .uk: "ПУБЛІЧНЕ ДОСЬЄ ОПЕРАТИВНИКА"
        }
    }
}
