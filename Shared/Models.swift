import Foundation
struct Coordinates: Codable { let latitude: Double; let longitude: Double; let accuracy: Double }
struct Person: Codable { let name: String; let avatar: String?; let paused: Bool; let location: Coordinates?; let updated: Double? }
struct PairState: Codable { let me: Person; let partner: Person? }
enum SharedStore {
    // AltStore may suffix App Group identifiers while resigning both targets.
    static var groupID: String {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let source = String(data: data, encoding: .isoLatin1),
           let start = source.range(of: "<?xml"), let end = source.range(of: "</plist>"),
           let xml = String(source[start.lowerBound..<end.upperBound]).data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let groups = entitlements["com.apple.security.application-groups"] as? [String],
           let group = groups.first(where: { $0.hasPrefix("group.com.personal.ryadom") }) { return group }
        return "group.com.personal.ryadom"
    }
    static let defaults = UserDefaults(suiteName: groupID)!
    static var state: PairState? {
        get { defaults.data(forKey: "state").flatMap { try? JSONDecoder().decode(PairState.self, from: $0) } }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "state") }
    }
}
