import Foundation
import Security
import WidgetKit

enum Vault {
    static let service = "com.personal.ryadom.session"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Не удалось сохранить ключ доступа") }
        } else if result != errSecSuccess { throw APIError.message("Не удалось обновить ключ доступа") }
    }
}
enum APIError: LocalizedError {
    case message(String)
    case unauthorized
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .unauthorized: return "Сервер не принял ключ доступа. Нажмите «Восстановить связь» в настройках."
        }
    }
}
@MainActor final class API: ObservableObject {
    static let shared = API()
    static let defaultEndpoint = "https://mikhail000.alwaysdata.net"
    @Published var state = SharedStore.state
    @Published var error: String?
    @Published var busy = false
    @Published var invite: String?
    @Published var notice: String?
    @Published var lastUploadAt: Date?
    @Published var sending = false
    @Published var connected = false
    @Published var endpoint: String = {
        let saved = UserDefaults.standard.string(forKey: "endpoint")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? API.defaultEndpoint : saved
    }()
    private var token = Vault.read()
    private var registration: Task<String, Error>?
    private var operations = 0
    private var boundEndpoint = UserDefaults.standard.string(forKey: "boundEndpoint")
    private func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    func request(_ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        let address = normalized(endpoint)
        guard let base = URL(string: address), base.scheme == "https", base.host != nil, base.user == nil, base.query == nil, base.fragment == nil else { throw APIError.message("Проверьте HTTPS-адрес сервера") }
        if let boundEndpoint, !boundEndpoint.isEmpty, normalized(boundEndpoint) != address { throw APIError.message("Аккаунт подключён к другому серверу. Верните прежний адрес или удалите аккаунт перед сменой сервера.") }
        var request = URLRequest(url: base.appendingPathComponent(path)); request.timeoutInterval = 25
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { connected = false; throw error }
        guard let http = response as? HTTPURLResponse else { throw APIError.message("Сервер не ответил") }
        if http.statusCode == 401 { connected = false; throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            connected = false
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.message(message ?? "Сервер временно недоступен. Повторите подключение.")
        }
        connected = true
        return data
    }
    private func ensureSession() async throws {
        guard token == nil else { return }
        let task: Task<String, Error>
        if let existing = registration { task = existing }
        else {
            task = Task {
                let data = try await self.request("register", [:])
                guard let value = (try JSONSerialization.jsonObject(with: data) as? [String: String])?["token"] else { throw APIError.message("Сервер не вернул ключ") }
                return value
            }
            registration = task
        }
        do {
            let value = try await task.value
            try Vault.save(value); token = value; boundEndpoint = normalized(endpoint)
            UserDefaults.standard.set(boundEndpoint, forKey: "boundEndpoint")
            registration = nil
        } catch { registration = nil; throw error }
    }
    func connect() async throws {
        if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { endpoint = Self.defaultEndpoint }
        try await ensureSession()
        UserDefaults.standard.set(normalized(endpoint), forKey: "endpoint")
        try await refresh()
    }
    func refresh() async throws {
        guard token != nil else { return }
        state = try JSONDecoder().decode(PairState.self, from: try await request("state"))
        SharedStore.state = state; WidgetCenter.shared.reloadAllTimelines()
    }
    @discardableResult func action(_ path: String, _ body: [String: Any] = [:]) async -> Bool {
        operations += 1; busy = true; notice = nil
        defer { operations -= 1; busy = operations > 0 }
        do {
            try await ensureSession()
            let data = try await request(path, body)
            if path == "invite" { invite = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String }
            if path == "delete" {
                try Vault.save(""); token = nil; boundEndpoint = nil; state = nil; SharedStore.state = nil; invite = nil
                UserDefaults.standard.removeObject(forKey: "boundEndpoint"); WidgetCenter.shared.reloadAllTimelines()
            } else { try await refresh() }
            notice = path == "invite" ? "Код готов — действует 10 минут" : path == "join" ? "Пара подключена" : path == "profile" ? "Профиль сохранён" : path == "pause" ? "Передача геопозиции остановлена" : "Готово"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func reconnect() async {
        operations += 1; busy = true; notice = nil
        defer { operations -= 1; busy = operations > 0 }
        do {
            do { try await connect(); notice = "Связь с сервером восстановлена" }
            catch APIError.unauthorized {
                try Vault.save(""); token = nil; boundEndpoint = nil; registration = nil
                UserDefaults.standard.removeObject(forKey: "boundEndpoint")
                state = nil; SharedStore.state = nil
                try await connect()
                notice = "Ключ обновлён. Если пара пропала, отключите старую пару на втором телефоне и подключитесь по новому коду."
            }
            if Position.shared.enabled { Position.shared.refreshNow() }
        } catch { self.error = error.localizedDescription }
    }
    func publish(_ location: Coordinates) async {
        guard Position.shared.enabled else { return }
        sending = true; defer { sending = false }
        do {
            try await ensureSession()
            guard Position.shared.enabled else { return }
            _ = try await request("location", ["latitude": location.latitude, "longitude": location.longitude, "accuracy": location.accuracy])
            if !Position.shared.enabled { _ = try await request("pause", [:]) }
            else { lastUploadAt = Date() }
            try await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
