import SceneKit
import SwiftUI

struct SpyOrbSceneView: UIViewRepresentable {
    var accent: UIColor = UIColor(red: 1.0, green: 0.34, blue: 0.35, alpha: 1.0)
    var intensity: CGFloat = 1

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling2X
        view.scene = makeScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: "accentLight", recursively: true)?.light?.intensity = 420 * intensity
        scene.rootNode.childNode(withName: "core", recursively: true)?.opacity = 0.84 + (0.08 * intensity)
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 34
        cameraNode.position = SCNVector3(0, 0.15, 6.4)
        scene.rootNode.addChildNode(cameraNode)

        let tiltRig = SCNNode()
        tiltRig.name = "tiltRig"
        scene.rootNode.addChildNode(tiltRig)

        let rig = SCNNode()
        rig.name = "orbRig"
        tiltRig.addChildNode(rig)

        let core = SCNNode(geometry: SCNSphere(radius: 1.0))
        core.name = "core"
        core.geometry?.firstMaterial = material(
            diffuse: UIColor(white: 1, alpha: 0.12),
            emission: UIColor(white: 1, alpha: 0.035),
            metalness: 0.16,
            roughness: 0.22,
            transparency: 0.58
        )
        rig.addChildNode(core)

        let inner = SCNNode(geometry: SCNSphere(radius: 0.64))
        inner.name = "innerCore"
        inner.geometry?.firstMaterial = material(
            diffuse: accent.withAlphaComponent(0.28),
            emission: accent.withAlphaComponent(0.18),
            metalness: 0.32,
            roughness: 0.18,
            transparency: 0.72
        )
        rig.addChildNode(inner)

        addRing(to: rig, radius: 1.28, tubeRadius: 0.012, euler: SCNVector3(0.8, 0.12, 0.18), alpha: 0.36)
        addRing(to: rig, radius: 1.46, tubeRadius: 0.009, euler: SCNVector3(1.44, 0.46, -0.34), alpha: 0.24)
        addRing(to: rig, radius: 1.66, tubeRadius: 0.007, euler: SCNVector3(0.28, 1.02, 0.6), alpha: 0.18)
        addDots(to: rig)

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .omni
        keyLight.light?.color = UIColor.white
        keyLight.light?.intensity = 520
        keyLight.position = SCNVector3(-2.4, 2.2, 3.2)
        scene.rootNode.addChildNode(keyLight)

        let accentLight = SCNNode()
        accentLight.name = "accentLight"
        accentLight.light = SCNLight()
        accentLight.light?.type = .omni
        accentLight.light?.color = accent
        accentLight.light?.intensity = 420 * intensity
        accentLight.position = SCNVector3(2.2, -1.2, 2.4)
        scene.rootNode.addChildNode(accentLight)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.7, alpha: 1)
        ambient.light?.intensity = 74
        scene.rootNode.addChildNode(ambient)

        rig.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: CGFloat.pi * 0.34, duration: 28)))
        inner.runAction(.repeatForever(.sequence([
            .scale(to: 1.08, duration: 3.2),
            .scale(to: 0.96, duration: 3.2)
        ])))

        return scene
    }

    private func addRing(to rig: SCNNode, radius: CGFloat, tubeRadius: CGFloat, euler: SCNVector3, alpha: CGFloat) {
        let ring = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: tubeRadius))
        ring.eulerAngles = euler
        ring.geometry?.firstMaterial = material(
            diffuse: accent.withAlphaComponent(alpha),
            emission: accent.withAlphaComponent(alpha * 0.42),
            metalness: 0.2,
            roughness: 0.18,
            transparency: alpha
        )
        rig.addChildNode(ring)
    }

    private func addDots(to rig: SCNNode) {
        for index in 0..<10 {
            let angle = Float(index) / 10 * Float.pi * 2
            let y = Float(index % 3 - 1) * 0.26
            let dot = SCNNode(geometry: SCNSphere(radius: index.isMultiple(of: 3) ? 0.035 : 0.026))
            dot.position = SCNVector3(cos(angle) * 1.52, y, sin(angle) * 1.52)
            dot.geometry?.firstMaterial = material(
                diffuse: UIColor.white.withAlphaComponent(0.42),
                emission: accent.withAlphaComponent(0.16),
                metalness: 0.1,
                roughness: 0.22,
                transparency: 0.55
            )
            rig.addChildNode(dot)
        }
    }

    private func material(
        diffuse: UIColor,
        emission: UIColor,
        metalness: CGFloat,
        roughness: CGFloat,
        transparency: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = diffuse
        material.emission.contents = emission
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        material.transparency = transparency
        material.blendMode = .alpha
        material.isDoubleSided = true
        return material
    }
}
