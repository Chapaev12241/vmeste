import Foundation
struct Coordinates: Codable { let latitude: Double; let longitude: Double; let accuracy: Double }
struct Person: Codable { let name: String; let avatar: String?; let paused: Bool; let location: Coordinates?; let updated: Double? }
struct PairState: Codable { let me: Person; let partner: Person? }
enum SharedStore {
    static let defaults = UserDefaults(suiteName: "group.com.personal.ryadom")!
    static var state: PairState? {
        get { defaults.data(forKey: "state").flatMap { try? JSONDecoder().decode(PairState.self, from: $0) } }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "state") }
    }
}
