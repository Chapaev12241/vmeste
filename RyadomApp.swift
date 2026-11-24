import SwiftUI
import MapKit
import CoreLocation
import PhotosUI
import WidgetKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Position.shared
        return true
    }
}
@main
struct RyadomApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup { Home() } }
}

@MainActor final class Position: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Position()
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var status = "Обмен выключен"
    @Published var enabled = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; enabled = UserDefaults.standard.bool(forKey: "sharingEnabled"); start() }
    func toggle() {
        enabled.toggle(); UserDefaults.standard.set(enabled, forKey: "sharingEnabled")
        if enabled { manager.requestWhenInUseAuthorization(); start() }
        else { manager.stopMonitoringSignificantLocationChanges(); manager.stopUpdatingLocation(); status = "Обмен выключен"; Task { await API.shared.action("pause") } }
    }
    func stopLocally() {
        enabled = false; UserDefaults.standard.set(false, forKey: "sharingEnabled")
        manager.stopMonitoringSignificantLocationChanges(); manager.stopUpdatingLocation(); status = "Обмен выключен"
    }
    func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
            if CLLocationManager.significantLocationChangeMonitoringAvailable() { manager.startMonitoringSignificantLocationChanges() }
            status = "Экономный режим"
        case .denied, .restricted: status = "Разрешите геопозицию в настройках"; enabled = false
        default: status = "Ожидание разрешения"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { start() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { location = locations.last
        if enabled, let location, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 120 {
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "Publish position", expirationHandler: nil)
            Task {
                await API.shared.publish(Coordinates(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy))
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            }
        } }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "Не удалось обновить геопозицию" }
    func enableBackground() { manager.requestAlwaysAuthorization() }
}

struct Home: View {
    @StateObject private var position = Position.shared
    @ObservedObject private var api = API.shared
    @Environment(\.scenePhase) private var phase
    @State private var code = ""
    @State private var confirmUnpair = false
    @State private var confirmDelete = false
    @AppStorage("name") private var name = "Я"
    @State private var photo: PhotosPickerItem?
    @State private var avatar: Data? = UserDefaults.standard.data(forKey: "avatar")
    @State private var settings = false
    private let ink = Color(red: 0.13, green: 0.21, blue: 0.19)
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map {
                    if let location = position.location {
                        Annotation(name, coordinate: location.coordinate) { avatarView.padding(5).background(.white).clipShape(Circle()) }
                    }
                    if let partner = api.state?.partner, !partner.paused, let point = partner.location {
                        Annotation(partner.name, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                            VStack {
                                if let encoded = partner.avatar, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(Circle()).padding(4).background(.white).clipShape(Circle()) }
                                else { Image(systemName: "heart.circle.fill").font(.largeTitle).foregroundStyle(.pink) }
                                Text(partner.name).font(.caption.bold()).padding(6).background(.regularMaterial).clipShape(Capsule()) }
                        }
                    }
                }.mapControls { MapCompass(); MapScaleView() }.ignoresSafeArea(edges: .bottom)
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("РЯДОМ").font(.custom("DOCKERONE", size: 32))
                            Text("Ваш маленький мир на двоих").font(.subheadline)
                        }
                        Spacer()
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").padding().background(.white).clipShape(Circle()) }.accessibilityLabel("Настройки")
                    }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 28))
                    Spacer()
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { avatarView; VStack(alignment: .leading) { Text(name).font(.title2.bold()); Text(position.status).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "leaf.fill") }
                        Text("Вместе — даже на расстоянии").font(.title3.bold())
                        if let partner = api.state?.partner {
                            HStack {
                                Text(partner.name).font(.headline)
                                if let own = position.location, let point = partner.location, !partner.paused {
                                    let distance = own.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                                    Text(distance < 1000 ? "\(Int(distance)) м от тебя" : String(format: "%.1f км от тебя", distance / 1000)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(partner.paused ? "Геопозиция на паузе" : "Последняя полученная позиция").font(.caption)
                            if let updated = partner.updated { Text(Date(timeIntervalSince1970: updated), style: .relative).font(.caption) }
                        } else { Button("Подключить пару") { settings = true } }
                        Button { position.toggle() } label: { Text(position.enabled ? "Приостановить геопозицию" : "Включить мою геопозицию").frame(maxWidth: .infinity).padding().background(ink).foregroundStyle(.white).clipShape(Capsule()) }
                        if let location = position.location { Text("Обновлено \(location.timestamp.formatted(date: .omitted, time: .shortened)) · точность ±\(Int(max(0, location.horizontalAccuracy))) м").font(.caption).foregroundStyle(.secondary) }
                    }.padding(24).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 30))
                }.padding(16)
            }.foregroundStyle(ink)
            .sheet(isPresented: $settings) {
                settingsView
            }
            .task {
                while !Task.isCancelled {
                    if phase == .active { do { try await api.refresh() } catch { api.error = error.localizedDescription } }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(get: { api.error != nil }, set: { if !$0 { api.error = nil } })) { Button("Понятно") { api.error = nil } } message: { Text(api.error ?? "") }
            .confirmationDialog("Удалить аккаунт и отключить пару?", isPresented: $confirmDelete) { Button("Удалить", role: .destructive) { position.stopLocally(); Task { await api.action("delete") } } }
            .confirmationDialog("Прекратить обмен и удалить позиции пары?", isPresented: $confirmUnpair) { Button("Отключить", role: .destructive) { position.stopLocally(); Task { await api.action("unpair") } } }
            .onChange(of: name) { _, value in Task { await api.action("profile", ["name": value, "avatar": avatar?.base64EncodedString() as Any? ?? NSNull()]) } }
            .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { if let image = UIImage(data: data) {
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160))
                    let resized = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 160, height: 160)) }
                    if let jpeg = resized.jpegData(compressionQuality: 0.65) { avatar = jpeg; UserDefaults.standard.set(jpeg, forKey: "avatar"); await api.action("profile", ["name": name, "avatar": jpeg.base64EncodedString()]) }
                } } } }
        }
    }
    private var settingsView: some View {
                NavigationStack { Form {
                    Section("Твой профиль") { TextField("Имя", text: $name); PhotosPicker(selection: $photo, matching: .images) { Label("Выбрать аватарку", systemImage: "photo") } }
                    Section("Подключение") {
                        TextField("https://ваш-сервер", text: $api.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Подключиться") { Task { do { try await api.connect() } catch { api.error = error.localizedDescription } } }
                        if api.state?.partner == nil {
                            Button("Создать код на 10 минут") { Task { await api.action("invite") } }
                            if let invite = api.invite { Text(invite).font(.title.monospaced()).textSelection(.enabled); ShareLink(item: "Подключись ко мне в Рядом. Сервер: \(api.endpoint), код: \(invite) (10 минут)") }
                            TextField("Код партнёра", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Button("Присоединиться") { Task { await api.action("join", ["code": code]) } }
                        } else { Button("Отключить пару", role: .destructive) { confirmUnpair = true } }
                        if api.busy { ProgressView() }
                    }
                    Section("Геопозиция") { Button("Разрешить обновления в фоне") { position.enableBackground() }; Text("Экономный режим обновляет позицию при существенном перемещении. Это не непрерывная трансляция."); Link("Открыть настройки iPhone", destination: URL(string: UIApplication.openSettingsURLString)!) }
                    Section { Button("Удалить мой аккаунт", role: .destructive) { confirmDelete = true } }
                    Section("О приложении") { Text("Рядом · версия исходников 0.1"); Text("Виджет показывает последнюю позицию, полученную приложением. iOS определяет время его обновления.") }
                }.navigationTitle("Наш мир").toolbar { Button("Готово") { settings = false } } }
    }
    @ViewBuilder var avatarView: some View {
        if let avatar, let image = UIImage(data: avatar) { Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle()) }
        else { Image(systemName: "person.fill").font(.title2).frame(width: 52, height: 52).background(.mint.opacity(0.3)).clipShape(Circle()) }
    }
}
