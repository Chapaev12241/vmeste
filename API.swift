import Foundation
import Security
import WidgetKit

enum Vault {
    static let service = "com.personal.ryadom.session"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnData as String:true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess, let data=result as? Data else { return nil }
        let value = String(data:data,encoding:.utf8)
        return value?.isEmpty == false ? value : nil
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service]
        SecItemDelete(query as CFDictionary)
        var attributes=query
        attributes[kSecValueData as String]=Data(token.utf8)
        attributes[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary,nil)==errSecSuccess else { throw APIError.message("Не удалось сохранить ключ") }
    }
}
enum APIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value)=self { return value }; return nil }
}
@MainActor final class API: ObservableObject {
    static let shared=API()
    @Published var state: PairState? = SharedStore.state
    @Published var error: String?
    @Published var busy=false
    @Published var invite: String?
    @Published var endpoint = UserDefaults.standard.string(forKey:"endpoint") ?? ""
    private var token=Vault.read()
    private var registration: Task<String, Error>?
    private var boundEndpoint: String? = UserDefaults.standard.string(forKey:"boundEndpoint")
    func request(_ path: String, _ body: [String:Any]? = nil) async throws -> Data {
        guard let base=URL(string:endpoint),base.scheme=="https",base.host != nil,base.user==nil,base.query==nil,base.fragment==nil else { throw APIError.message("Укажите HTTPS-адрес вашего сервера") }
        if let boundEndpoint, boundEndpoint != endpoint { throw APIError.message("Для смены сервера сначала удалите аккаунт на текущем сервере") }
        var req=URLRequest(url:base.appendingPathComponent(path)); req.timeoutInterval=20
        req.httpMethod=body == nil ? "GET":"POST"
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let token { req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }
        if let body { req.httpBody=try JSONSerialization.data(withJSONObject:body) }
        let (data,response)=try await URLSession.shared.data(for:req)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            let message=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["error"] as? String
            throw APIError.message(message ?? "Не удалось связаться с сервером")
        }
        return data
    }
    func connect() async throws {
        if token==nil {
            if registration == nil {
                registration = Task {
                    let data = try await self.request("register", [:])
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
                    guard let value = object?["token"] else { throw APIError.message("Сервер не вернул ключ") }
                    return value
                }
            }
            let newToken: String
            do { newToken = try await registration!.value } catch { registration = nil; throw error }
            registration = nil
            try Vault.save(newToken); token=newToken; boundEndpoint=endpoint
            UserDefaults.standard.set(endpoint,forKey:"boundEndpoint")
        }
        UserDefaults.standard.set(endpoint,forKey:"endpoint")
        try await refresh()
    }
    func refresh() async throws {
        guard token != nil else { return }
        state=try JSONDecoder().decode(PairState.self,from: try await request("state"))
        SharedStore.state=state; WidgetCenter.shared.reloadAllTimelines()
    }
    func action(_ path: String, _ body: [String:Any]=[:]) async {
        busy=true; defer { busy=false }
        do {
            try await connect()
            let data=try await request(path,body)
            if path=="invite" { invite=(try JSONSerialization.jsonObject(with:data) as? [String:Any])?["code"] as? String }
            if path=="delete" {
                token=nil; boundEndpoint=nil; try Vault.save(""); state=nil; SharedStore.state=nil
                UserDefaults.standard.removeObject(forKey:"boundEndpoint")
                WidgetCenter.shared.reloadAllTimelines()
            } else { try await refresh() }
        } catch { self.error=error.localizedDescription }
    }
    func publish(_ location: Coordinates) async {
        do { try await connect(); _=try await request("location",["latitude":location.latitude,"longitude":location.longitude,"accuracy":location.accuracy])
            if !Position.shared.enabled { _ = try await request("pause", [:]) }
            try await refresh() }
        catch { self.error=error.localizedDescription }
    }
}
