import UIKit
import SceneKit
import Metal

/// Lightweight, original low-poly hatchback inspired by the 2016 Toyota Passo.
/// The scene is rasterized only for a new heading sector; there is no live SCNView.
enum CarMarker {
    private static var cache: [Int: UIImage] = [:]
    private static let scene: SCNScene = makeScene()
    private static let renderer: SCNRenderer = {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        renderer.autoenablesDefaultLighting = false
        return renderer
    }()
    static func headingSector(_ heading: Double) -> Int {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        return (Int((normalized + 360) / 15.0 + 0.5) % 24 + 24) % 24
    }
    static func image(heading: Double) -> UIImage {
        let sector = headingSector(heading)
        if let image = cache[sector] { return image }
        scene.rootNode.childNode(withName: "car", recursively: false)?.eulerAngles.y = Float(Double(sector) * 15 * .pi / 180)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 88, height: 88), antialiasingMode: .multisampling2X)
        cache[sector] = image
        return image
    }
    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        let car = SCNNode(); car.name = "car"; scene.rootNode.addChildNode(car)
        func material(_ color: UIColor, gloss: CGFloat = 0.35) -> SCNMaterial {
            let material = SCNMaterial(); material.diffuse.contents = color
            material.lightingModel = .blinn
            material.specular.contents = UIColor.white.withAlphaComponent(gloss)
            material.shininess = gloss * 80
            return material
        }
        let white = material(UIColor(white: 0.98, alpha: 1), gloss: 0.6)
        let glass = material(UIColor(red: 0.075, green: 0.13, blue: 0.18, alpha: 1), gloss: 0.7)
        let rubber = material(UIColor(white: 0.065, alpha: 1), gloss: 0)
        let metal = material(UIColor(white: 0.63, alpha: 1), gloss: 0.65)
        @discardableResult func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, _ radius: CGFloat, _ position: SCNVector3, _ material: SCNMaterial) -> SCNNode {
            let safeRadius = min(radius, min(width, min(height, length)) * 0.45)
            let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: safeRadius)
            geometry.chamferSegmentCount = 3
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.position = position; car.addChildNode(node)
            return node
        }
        box(0.84, 0.33, 1.53, 0.12, SCNVector3(0, 0.39, 0), white)
        box(0.70, 0.36, 0.91, 0.12, SCNVector3(0, 0.69, -0.10), white)
        // Windscreen, rear glass and two side windows, separated by white door pillars.
        let windshield = box(0.59, 0.25, 0.025, 0.035, SCNVector3(0, 0.70, 0.35), glass)
        windshield.eulerAngles.x = -0.23
        box(0.58, 0.23, 0.025, 0.025, SCNVector3(0, 0.70, -0.56), glass)
        for side in [Float(-1), Float(1)] {
            box(0.018, 0.22, 0.30, 0.025, SCNVector3(side * 0.35, 0.70, 0.12), glass)
            box(0.018, 0.22, 0.30, 0.025, SCNVector3(side * 0.35, 0.70, -0.25), glass)
            box(0.075, 0.055, 0.13, 0.025, SCNVector3(side * 0.44, 0.63, 0.25), white)
            for z in [Float(-0.51), Float(0.49)] {
                let tyre = SCNCylinder(radius: 0.17, height: 0.11); tyre.radialSegmentCount = 12; tyre.materials = [rubber]
                let wheel = SCNNode(geometry: tyre); wheel.eulerAngles.z = .pi / 2; wheel.position = SCNVector3(side * 0.40, 0.20, z); car.addChildNode(wheel)
                let rim = SCNCylinder(radius: 0.10, height: 0.115); rim.radialSegmentCount = 10; rim.materials = [metal]
                let hub = SCNNode(geometry: rim); hub.eulerAngles.z = .pi / 2; hub.position = wheel.position; car.addChildNode(hub)
            }
            let lamp = material(UIColor(red: 1, green: 0.96, blue: 0.78, alpha: 1), gloss: 0.6)
            box(0.19, 0.11, 0.035, 0.035, SCNVector3(side * 0.24, 0.47, 0.745), lamp)
            box(0.12, 0.18, 0.035, 0.025, SCNVector3(side * 0.29, 0.46, -0.75), material(.systemRed))
            for z in [Float(-0.20), Float(0.21)] { box(0.026, 0.025, 0.095, 0.01, SCNVector3(side * 0.416, 0.51, z), metal) }
        }
        box(0.48, 0.095, 0.025, 0.02, SCNVector3(0, 0.31, 0.774), rubber)
        box(0.20, 0.06, 0.028, 0.005, SCNVector3(0, 0.40, 0.78), material(.white))
        let camera = SCNNode(); camera.name = "camera"; camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 1.18
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 30
        camera.position = SCNVector3(2.1, 3.6, 3.4)
        let aim = SCNNode(); aim.position = SCNVector3(0, 0.42, 0); scene.rootNode.addChildNode(aim)
        let constraint = SCNLookAtConstraint(target: aim); constraint.isGimbalLockEnabled = true; camera.constraints = [constraint]
        scene.rootNode.addChildNode(camera)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 950
        sun.eulerAngles = SCNVector3(-0.8, -0.5, 0); scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 450; scene.rootNode.addChildNode(ambient)
        return scene
    }
}
