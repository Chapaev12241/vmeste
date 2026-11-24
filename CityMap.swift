import SwiftUI
import MapLibre
import CoreLocation

struct MapPerson: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let avatar: Data?
    let isMe: Bool
    var isDriving = false
    var heading: Double = 0
}

/// Wait for a real viewport before calculating the camera. A zero-size map turns
/// altitude into a world-scale camera, which was the cause of the initial zoom bug.
final class ReadyCityMapView: MLNMapView {
    var onViewportReady: ((MLNMapView) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 1 && bounds.height > 1 { onViewportReady?(self) }
    }
}

struct CityMap: UIViewRepresentable {
    let people: [MapPerson]
    let is3D: Bool
    let target: CLLocationCoordinate2D
    let revision: Int
    let fitPair: Bool
    var onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "CitySatellite", withExtension: "json") ?? URL(string: "https://tiles.openfreemap.org/styles/liberty")!
        let map = ReadyCityMapView(frame: .zero, styleURL: styleURL)
        let coordinator = context.coordinator
        map.delegate = coordinator
        map.onViewportReady = { [weak coordinator] map in coordinator?.applyInitialCamera(to: map) }
        map.minimumZoomLevel = 4
        map.maximumZoomLevel = 19
        map.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : MLNMapViewPreferredFramesPerSecond(rawValue: 60)
        map.logoView.isHidden = true
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 10, y: 165)
        map.compassView.isHidden = true
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.syncAnnotations(on: map)
        coordinator.applyInitialCamera(to: map)
        guard coordinator.initialCameraApplied else { return }
        if coordinator.revision != revision || coordinator.is3D != is3D {
            let changedTarget = coordinator.revision != revision
            coordinator.revision = revision; coordinator.is3D = is3D
            let animate = !UIAccessibility.isReduceMotionEnabled
            if changedTarget && fitPair && people.count > 1 {
                map.showAnnotations(map.annotations ?? [], edgePadding: UIEdgeInsets(top: 120, left: 65, bottom: 170, right: 65), animated: animate)
            } else {
                let camera = map.camera
                if changedTarget { camera.centerCoordinate = target }
                camera.pitch = is3D ? 55 : 0
                map.setCamera(camera, animated: animate)
            }
        }
    }
    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) {
        uiView.delegate = nil
        (uiView as? ReadyCityMapView)?.onViewportReady = nil
    }
    final class PersonAnnotation: MLNPointAnnotation {
        var person: MapPerson?
        var imageKey = ""
    }
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: CityMap
        var revision: Int
        var is3D: Bool
        var styleLoaded = false
        var initialCameraApplied = false
        private var annotations: [String: PersonAnnotation] = [:]
        private var imageCache: [String: UIImage] = [:]
        private var lastHeadingSector = -1
        init(_ parent: CityMap) { self.parent = parent; revision = parent.revision; is3D = parent.is3D }

        func applyInitialCamera(to map: MLNMapView) {
            guard styleLoaded, !initialCameraApplied, map.bounds.width > 1, map.bounds.height > 1 else { return }
            initialCameraApplied = true
            revision = parent.revision; is3D = parent.is3D
            map.setCenter(parent.target, zoomLevel: 15.9, direction: -18, animated: false)
            let camera = map.camera; camera.pitch = parent.is3D ? 55 : 0
            map.setCamera(camera, animated: false)
        }
        func syncAnnotations(on map: MLNMapView) {
            let ids = Set(parent.people.map(\.id))
            for id in Array(annotations.keys) where !ids.contains(id) {
                if let annotation = annotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }
            }
            for person in parent.people {
                let heading = person.heading - map.direction
                let visualKey = person.isDriving
                    ? "car:\(CarMarker.headingSector(heading))"
                    : "avatar:\(person.id):\(person.name):\(person.avatar?.hashValue ?? 0)"
                if let existing = annotations[person.id], existing.imageKey == visualKey {
                    existing.person = person; existing.title = person.name
                    if existing.coordinate.latitude != person.coordinate.latitude || existing.coordinate.longitude != person.coordinate.longitude { existing.coordinate = person.coordinate }
                    continue
                }
                if let old = annotations.removeValue(forKey: person.id) { map.removeAnnotation(old) }
                let point = PersonAnnotation(); point.coordinate = person.coordinate; point.title = person.name; point.person = person; point.imageKey = visualKey
                annotations[person.id] = point
                if imageCache[visualKey] == nil {
                    if imageCache.count > 64 { imageCache.removeAll(keepingCapacity: true) }
                    imageCache[visualKey] = person.isDriving ? CarMarker.image(heading: heading) : Self.avatarImage(person)
                }
                map.addAnnotation(point)
            }
        }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            style.setImage(Self.facadePattern, forName: "ryadom-facade")
            if let buildings = style.layers.first(where: { $0 is MLNFillExtrusionStyleLayer }) as? MLNFillExtrusionStyleLayer {
                buildings.minimumZoomLevel = 15.4
                buildings.fillExtrusionPattern = NSExpression(forConstantValue: "ryadom-facade")
                buildings.fillExtrusionOpacity = NSExpression(forConstantValue: 1)
            }
            applyInitialCamera(to: mapView)
        }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let sector = CarMarker.headingSector(mapView.direction)
            guard sector != lastHeadingSector else { return }
            lastHeadingSector = sector
            if parent.people.contains(where: { $0.isDriving }) { syncAnnotations(on: mapView) }
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { DispatchQueue.main.async { self.parent.onFailure() } }
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let point = annotation as? PersonAnnotation, let image = imageCache[point.imageKey] else { return nil }
            return MLNAnnotationImage(image: image, reuseIdentifier: point.imageKey)
        }
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }

        private static let facadePattern: UIImage = {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { _ in
                UIColor(red: 0.70, green: 0.70, blue: 0.66, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor(white: 1, alpha: 0.12).setFill()
                for y in stride(from: 0, to: 64, by: 8) { UIRectFill(CGRect(x: 0, y: CGFloat(y), width: 64, height: 1)) }
                for y in [8, 38] {
                    for x in [8, 38] {
                        UIColor(red: 0.86, green: 0.86, blue: 0.82, alpha: 1).setFill(); UIRectFill(CGRect(x: CGFloat(x - 2), y: CGFloat(y - 2), width: 17, height: 20))
                        UIColor(red: 0.27, green: 0.34, blue: 0.37, alpha: 1).setFill(); UIRectFill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 13, height: 16))
                        UIColor(white: 0.91, alpha: 1).setFill(); UIRectFill(CGRect(x: CGFloat(x + 6), y: CGFloat(y), width: 1, height: 16)); UIRectFill(CGRect(x: CGFloat(x), y: CGFloat(y + 7), width: 13, height: 1))
                    }
                }
            }
        }()
        private static func avatarImage(_ person: MapPerson) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            return UIGraphicsImageRenderer(size: CGSize(width: 58, height: 68), format: format).image { context in
                let color = person.isMe ? UIColor(red: 0.40, green: 0.34, blue: 0.90, alpha: 1) : UIColor(red: 1, green: 0.49, blue: 0.40, alpha: 1)
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 4, color: UIColor.black.withAlphaComponent(0.17).cgColor)
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 4, y: 3, width: 50, height: 50)).fill()
                context.cgContext.setShadow(offset: .zero, blur: 0)
                let circle = UIBezierPath(ovalIn: CGRect(x: 8, y: 7, width: 42, height: 42)); color.setFill(); circle.fill()
                if let data = person.avatar, let photo = UIImage(data: data) { context.cgContext.saveGState(); circle.addClip(); photo.draw(in: CGRect(x: 8, y: 7, width: 42, height: 42)); context.cgContext.restoreGState() }
                else { (String(person.name.prefix(1)).uppercased() as NSString).draw(at: CGPoint(x: 21, y: 15), withAttributes: [.font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: UIColor.white]) }
                color.setFill(); UIBezierPath(ovalIn: CGRect(x: 24, y: 57, width: 10, height: 5)).fill()
            }
        }
    }
}
