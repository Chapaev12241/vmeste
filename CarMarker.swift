import UIKit
import SceneKit
import Metal

/// Lightweight, original low-poly hatchback inspired by the 2016 Toyota Passo.
/// The scene is rasterized only for a new heading sector; there is no live SCNView.
enum CarMarker {
    private static var cache: [Int: UIImage] = [:]
    private static let scene: SCNScene = makeScene(night: false)
    private static let nightScene: SCNScene = makeScene(night: true)
    private static let device = MTLCreateSystemDefaultDevice()
    private static let renderer = makeRenderer(scene: scene)
    private static let nightRenderer = makeRenderer(scene: nightScene)
    private static func makeRenderer(scene: SCNScene) -> SCNRenderer {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        renderer.autoenablesDefaultLighting = false
        return renderer
    }
    /// Local phone time; no location or network lookup is needed.
    static func isNight(at date: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 20 || hour < 7
    }
    static func headingSector(_ heading: Double) -> Int {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        return (Int((normalized + 360) / 15.0 + 0.5) % 24 + 24) % 24
    }
    static func image(heading: Double, night: Bool = CarMarker.isNight()) -> UIImage {
        let sector = headingSector(heading)
        let key = sector + (night ? 24 : 0)
        if let image = cache[key] { return image }
        let activeScene = night ? nightScene : scene
        let activeRenderer = night ? nightRenderer : renderer
        activeScene.rootNode.childNode(withName: "car", recursively: false)?.eulerAngles.y = Float(Double(sector) * 15 * .pi / 180)
        let side: CGFloat = night ? 104 : 88
        let image = activeRenderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling2X)
        cache[key] = image
        return image
    }
    private static func makeScene(night: Bool) -> SCNScene {
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
            if night { lamp.emission.contents = UIColor(red: 1, green: 0.93, blue: 0.60, alpha: 1); lamp.emission.intensity = 2.2 }
            box(0.19, 0.11, 0.035, 0.035, SCNVector3(side * 0.24, 0.47, 0.745), lamp)
            let tailLamp = material(.systemRed)
            if night { tailLamp.emission.contents = UIColor.systemRed; tailLamp.emission.intensity = 0.85 }
            box(0.12, 0.18, 0.035, 0.025, SCNVector3(side * 0.29, 0.46, -0.75), tailLamp)
            for z in [Float(-0.20), Float(0.21)] { box(0.026, 0.025, 0.095, 0.01, SCNVector3(side * 0.416, 0.51, z), metal) }
        }
        box(0.48, 0.095, 0.025, 0.02, SCNVector3(0, 0.31, 0.774), rubber)
        box(0.20, 0.06, 0.028, 0.005, SCNVector3(0, 0.40, 0.78), material(.white))
        if night { addHeadlightBeams(to: car) }
        let camera = SCNNode(); camera.name = "camera"; camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = night ? 1.48 : 1.18
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 30
        camera.position = SCNVector3(2.1, 3.6, 3.4)
        let aim = SCNNode(); aim.position = SCNVector3(0, 0.42, 0); scene.rootNode.addChildNode(aim)
        let constraint = SCNLookAtConstraint(target: aim); constraint.isGimbalLockEnabled = true; camera.constraints = [constraint]
        scene.rootNode.addChildNode(camera)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = night ? 260 : 950
        sun.eulerAngles = SCNVector3(-0.8, -0.5, 0); scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = night ? 240 : 450; scene.rootNode.addChildNode(ambient)
        return scene
    }
    /// Two low-poly luminous volumes. They are rasterized into the cached marker,
    /// so the map does not run a lighting pass or a live 3D scene while moving.
    private static func addHeadlightBeams(to car: SCNNode) {
        for side in [Float(-1), Float(1)] {
            let beamMaterial = SCNMaterial()
            beamMaterial.lightingModel = .constant
            beamMaterial.diffuse.contents = UIColor(red: 1, green: 0.94, blue: 0.64, alpha: 0.18)
            beamMaterial.emission.contents = UIColor(red: 1, green: 0.92, blue: 0.56, alpha: 1)
            beamMaterial.emission.intensity = 0.45
            beamMaterial.isDoubleSided = true
            beamMaterial.writesToDepthBuffer = false
            beamMaterial.blendMode = .add
            beamMaterial.transparency = 0.22
            let cone = SCNCone(topRadius: 0.035, bottomRadius: 0.29, height: 0.96)
            cone.radialSegmentCount = 12; cone.heightSegmentCount = 1
            cone.materials = [beamMaterial]
            let beam = SCNNode(geometry: cone)
            beam.name = side < 0 ? "headlight-beam-left" : "headlight-beam-right"
            beam.position = SCNVector3(side * 0.24, 0.34, 1.22)
            beam.eulerAngles.x = -.pi / 2
            beam.renderingOrder = 10
            car.addChildNode(beam)

            let glow = SCNMaterial(); glow.lightingModel = .constant
            glow.diffuse.contents = UIColor(red: 1, green: 0.96, blue: 0.78, alpha: 1)
            glow.emission.contents = UIColor(red: 1, green: 0.94, blue: 0.66, alpha: 1)
            glow.emission.intensity = 2
            let bulb = SCNSphere(radius: 0.055); bulb.segmentCount = 10; bulb.materials = [glow]
            let bulbNode = SCNNode(geometry: bulb)
            bulbNode.position = SCNVector3(side * 0.24, 0.47, 0.775)
            car.addChildNode(bulbNode)
        }
    }

}
