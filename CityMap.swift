import SwiftUI
import MapLibre
import CoreLocation

struct MapPerson: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let avatar: Data?
    let isMe: Bool
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
        let map = MLNMapView(frame: .zero, styleURL: URL(string: "https://tiles.openfreemap.org/styles/liberty"))
        map.delegate = context.coordinator
        map.minimumZoomLevel = 3
        map.maximumZoomLevel = 19
        map.preferredFramesPerSecond = .lowPower
        map.logoView.isHidden = true
        // Provider and OpenStreetMap attribution remain available through the info control.
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 10, y: 165)
        map.compassViewPosition = .topRight
        map.compassView.isHidden = true
        map.setCenter(target, zoomLevel: 15.7, direction: -18, animated: false)
        map.camera = MLNMapCamera(lookingAtCenter: target, altitude: 1250, pitch: is3D ? 58 : 0, heading: -18)
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let signature = people.map { "\($0.id):\($0.name):\($0.coordinate.latitude):\($0.coordinate.longitude):\($0.avatar?.hashValue ?? 0)" }.joined()
        if signature != coordinator.signature {
            coordinator.signature = signature
            if let annotations = map.annotations { map.removeAnnotations(annotations) }
            for person in people {
                let point = PersonAnnotation()
                point.coordinate = person.coordinate; point.title = person.name; point.person = person
                map.addAnnotation(point)
            }
        }
        if coordinator.revision != revision || coordinator.is3D != is3D {
            coordinator.revision = revision; coordinator.is3D = is3D
            if fitPair && people.count > 1 {
                map.showAnnotations(map.annotations ?? [], edgePadding: UIEdgeInsets(top: 120, left: 65, bottom: 170, right: 65), animated: true)
            } else {
                let center = coordinator.lastTargetRevision == revision ? map.centerCoordinate : target
                coordinator.lastTargetRevision = revision
                let camera = MLNMapCamera(lookingAtCenter: center, altitude: max(600, min(map.camera.altitude, 4000)), pitch: is3D ? 58 : 0, heading: map.direction)
                map.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
    final class PersonAnnotation: MLNPointAnnotation { var person: MapPerson? }
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: CityMap
        var signature = ""
        var revision = 0
        var lastTargetRevision = 0
        var is3D = true
        init(_ parent: CityMap) { self.parent = parent }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            if let existing = style.layers.first(where: { $0 is MLNFillExtrusionStyleLayer }) as? MLNFillExtrusionStyleLayer {
                existing.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.77, green: 0.78, blue: 0.87, alpha: 1))
                existing.fillExtrusionOpacity = NSExpression(forConstantValue: 0.96)
                return
            }
            guard let source = style.source(withIdentifier: "openmaptiles") else { return }
            let buildings = MLNFillExtrusionStyleLayer(identifier: "ryadom-buildings-3d", source: source)
            buildings.sourceLayerIdentifier = "building"
            buildings.minimumZoomLevel = 14
            buildings.fillExtrusionHeight = NSExpression(forKeyPath: "render_height")
            buildings.fillExtrusionBase = NSExpression(forKeyPath: "render_min_height")
            buildings.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.77, green: 0.78, blue: 0.87, alpha: 1))
            buildings.fillExtrusionOpacity = NSExpression(forConstantValue: 0.94)
            if let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) { style.insertLayer(buildings, below: labels) }
            else { style.addLayer(buildings) }
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { DispatchQueue.main.async { self.parent.onFailure() } }
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let point = annotation as? PersonAnnotation, let person = point.person else { return nil }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 58, height: 68)).image { context in
                let color = person.isMe ? UIColor(red: 0.40, green: 0.34, blue: 0.90, alpha: 1) : UIColor(red: 1, green: 0.49, blue: 0.40, alpha: 1)
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 5, color: UIColor.black.withAlphaComponent(0.22).cgColor)
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 4, y: 3, width: 50, height: 50)).fill()
                context.cgContext.setShadow(offset: .zero, blur: 0)
                let circle = UIBezierPath(ovalIn: CGRect(x: 8, y: 7, width: 42, height: 42))
                color.setFill(); circle.fill()
                if let data = person.avatar, let photo = UIImage(data: data) { context.cgContext.saveGState(); circle.addClip(); photo.draw(in: CGRect(x: 8, y: 7, width: 42, height: 42)); context.cgContext.restoreGState() }
                else {
                    let text = String(person.name.prefix(1)).uppercased() as NSString
                    text.draw(at: CGPoint(x: 21, y: 15), withAttributes: [.font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: UIColor.white])
                }
                color.setFill(); UIBezierPath(ovalIn: CGRect(x: 24, y: 57, width: 10, height: 5)).fill()
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: person.id + String(person.avatar?.hashValue ?? 0))
        }
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }
    }
}
