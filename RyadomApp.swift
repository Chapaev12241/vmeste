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

@MainActor final class Position: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
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

enum MapLook: String, CaseIterable { case city = "Город", satellite = "Спутник" }
struct Home: View {
    private static let yuzhny = CLLocationCoordinate2D(latitude: 46.9591, longitude: 142.7380)
    @StateObject private var position = Position.shared
    @ObservedObject private var api = API.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var code = ""
    @State private var confirmUnpair = false
    @State private var confirmDelete = false
    @AppStorage("name") private var name = "Я"
    @State private var photo: PhotosPickerItem?
    @State private var avatar = UserDefaults.standard.data(forKey: "avatar")
    @State private var settings = false
    @State private var details = false
    @State private var is3D = true
    @State private var look = MapLook.city
    @State private var target = Home.yuzhny
    @State private var revision = 0
    @State private var fitPair = false
    @State private var mapFailed = false
    @State private var satelliteCamera: MapCameraPosition = .camera(MapCamera(centerCoordinate: Home.yuzhny, distance: 1800, heading: -18, pitch: 58))
    private let accent = Color(red: 0.40, green: 0.34, blue: 0.90)
    private let coral = Color(red: 1, green: 0.49, blue: 0.40)
    private var people: [MapPerson] {
        var result: [MapPerson] = []
        if let own = position.location { result.append(MapPerson(id: "me", name: name, coordinate: own.coordinate, avatar: avatar, isMe: true)) }
        if let partner = api.state?.partner, !partner.paused, let point = partner.location {
            result.append(MapPerson(id: "partner", name: partner.name, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), avatar: partner.avatar.flatMap { Data(base64Encoded: $0) }, isMe: false))
        }
        return result
    }
    var body: some View {
        ZStack {
            mapCanvas.ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) { header.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8) }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls.padding(.horizontal, 16).padding(.bottom, 8) }
        .sheet(isPresented: $settings) {
            settingsView.tint(accent)
                .alert("Не удалось выполнить действие", isPresented: Binding(get: { api.error != nil && settings }, set: { if !$0 { api.error = nil } })) { Button("Понятно") { api.error = nil } } message: { Text(api.error ?? "") }
                .confirmationDialog("Удалить аккаунт и отключить пару?", isPresented: $confirmDelete) { Button("Удалить", role: .destructive) { position.stopLocally(); Task { await api.action("delete") } } }
                .confirmationDialog("Прекратить обмен и удалить позиции пары?", isPresented: $confirmUnpair) { Button("Отключить", role: .destructive) { position.stopLocally(); Task { await api.action("unpair") } } }
        }
        .sheet(isPresented: $details) { personDetails.presentationDetents([.height(290), .medium]).presentationDragIndicator(.visible) }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { api.error != nil && !settings && !details }, set: { if !$0 { api.error = nil } })) { Button("Понятно") { api.error = nil } } message: { Text(api.error ?? "") }
        .task {
            while !Task.isCancelled {
                if phase == .active { do { try await api.refresh() } catch { api.error = error.localizedDescription } }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: name) { _, value in Task { await api.action("profile", ["name": value, "avatar": avatar?.base64EncodedString() as Any? ?? NSNull()]) } }
        .onChange(of: photo) { _, item in Task { await savePhoto(item) } }
        .tint(accent)
    }
    @ViewBuilder private var mapCanvas: some View {
        if look == .city {
            CityMap(people: people, is3D: is3D, target: target, revision: revision, fitPair: fitPair) { mapFailed = true; look = .satellite }
        } else {
            Map(position: $satelliteCamera) {
                ForEach(people) { person in
                    Annotation(person.name, coordinate: person.coordinate) {
                        ProfileBubble(data: person.avatar, name: person.name, color: person.isMe ? accent : coral, size: 42)
                            .padding(4).background(.background, in: Circle()).shadow(color: .black.opacity(0.16), radius: 5, y: 3)
                    }
                }
            }.mapStyle(.hybrid(elevation: .realistic)).mapControls { MapCompass(); MapScaleView() }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 16, weight: .bold)).foregroundStyle(accent)
                Text("РЯДОМ").font(.custom("DOCKERONE", size: 19))
            }.padding(.horizontal, 15).frame(height: 44).background(.regularMaterial, in: Capsule())
            Spacer(minLength: 0)
            Button { focus(Self.yuzhny) } label: {
                HStack(spacing: 4) { Text("Южно-Сахалинск").font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    .padding(.horizontal, 12).frame(minHeight: 44).background(.regularMaterial, in: Capsule())
            }.accessibilityLabel("Вернуться к Южно-Сахалинску")
            Button { settings = true } label: { ProfileBubble(data: avatar, name: name, color: accent, size: 38).padding(3).background(.regularMaterial, in: Circle()) }.accessibilityLabel("Профиль и настройки")
        }.foregroundStyle(.primary)
    }
    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                if mapFailed { Text("3D-карта не загрузилась. Открыт спутник.").font(.caption).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).frame(maxWidth: 210) }
                Spacer()
                VStack(spacing: 10) {
                    Button { changeDimension() } label: { Text(is3D ? "3D" : "2D").font(.system(size: 15, weight: .bold, design: .rounded)).frame(width: 46, height: 46).background(.regularMaterial, in: Circle()) }.accessibilityLabel(is3D ? "Переключить в 2D" : "Переключить в 3D")
                    Button { if let own = position.location { focus(own.coordinate) } else { position.start() } } label: { Image(systemName: "location.fill").font(.system(size: 18, weight: .semibold)).frame(width: 46, height: 46).background(.regularMaterial, in: Circle()) }.accessibilityLabel("Моя геопозиция").disabled(position.location == nil)
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(MapLook.allCases, id: \.self) { option in
                        Button { look = option; mapFailed = false } label: {
                            Text(option.rawValue).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).frame(height: 36)
                                .background(look == option ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear), in: Capsule())
                                .foregroundStyle(look == option ? .white : .primary)
                        }
                    }
                }.padding(4).background(.regularMaterial, in: Capsule())
                Spacer()
                Button { fitBoth() } label: { Label("Мы", systemImage: "person.2.fill").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).frame(height: 44).background(.regularMaterial, in: Capsule()) }.disabled(people.count < 2)
            }
            partnerCard
        }
    }
    private var partnerCard: some View {
        HStack(spacing: 12) {
            Button { if api.state?.partner != nil { details = true } else { settings = true } } label: {
                HStack(spacing: 12) {
                    ProfileBubble(data: api.state?.partner?.avatar.flatMap { Data(base64Encoded: $0) }, name: api.state?.partner?.name ?? "♡", color: coral, size: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) { Text(api.state?.partner?.name ?? "Добавить любимого человека").font(.system(size: 15, weight: .semibold)).lineLimit(1); if api.state?.partner != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary) } }
                        if let partner = api.state?.partner {
                            HStack(spacing: 5) {
                                Circle().fill(partner.paused ? Color.secondary : coral).frame(width: 5, height: 5)
                                Text(partner.paused ? "Геопозиция на паузе" : distanceText).lineLimit(1)
                                if !partner.paused, let timestamp = partner.updated { Text("·"); Text(Date(timeIntervalSince1970: timestamp), style: .relative).lineLimit(1) }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                        } else { Text("Подключитесь по одному коду").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { position.toggle() } label: {
                Image(systemName: position.enabled ? "pause.fill" : "location.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(accent, in: Circle())
            }.accessibilityLabel(position.enabled ? "Приостановить мою геопозицию" : "Включить мою геопозицию")
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.4), lineWidth: 0.5)).shadow(color: .black.opacity(0.09), radius: 18, y: 6)
    }
    private var distanceText: String {
        guard let own = position.location, let point = api.state?.partner?.location else { return "Ждём геопозицию" }
        let distance = own.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
        return distance < 1000 ? "\(Int(distance)) м от тебя" : String(format: "%.1f км от тебя", distance / 1000)
    }
    private var personDetails: some View {
        VStack(spacing: 16) {
            ProfileBubble(data: api.state?.partner?.avatar.flatMap { Data(base64Encoded: $0) }, name: api.state?.partner?.name ?? "♡", color: coral, size: 64)
            Text(api.state?.partner?.name ?? "Твоя пара").font(.title2.bold())
            Text(api.state?.partner?.paused == true ? "Геопозиция на паузе" : distanceText).foregroundStyle(.secondary)
            if let timestamp = api.state?.partner?.updated { HStack { Text("Последнее обновление"); Text(Date(timeIntervalSince1970: timestamp), style: .relative) }.font(.caption).foregroundStyle(.secondary) }
            Button("Показать на карте") {
                if let point = api.state?.partner?.location { focus(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) }
                details = false
            }.buttonStyle(.borderedProminent).disabled(api.state?.partner?.location == nil)
        }.padding(24).frame(maxWidth: .infinity)
    }
    private func focus(_ coordinate: CLLocationCoordinate2D) {
        target = coordinate; fitPair = false; revision += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) { satelliteCamera = .camera(MapCamera(centerCoordinate: coordinate, distance: 1800, heading: -18, pitch: is3D ? 58 : 0)) }
    }
    private func fitBoth() {
        guard people.count > 1 else { return }; fitPair = true; revision += 1
        var rect = MKMapRect.null
        for person in people { let point = MKMapPoint(person.coordinate); rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1)) }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) { satelliteCamera = .rect(rect.insetBy(dx: -max(500, rect.width * 0.35), dy: -max(500, rect.height * 0.35))) }
    }
    private func changeDimension() {
        is3D.toggle()
        if var camera = satelliteCamera.camera { camera.pitch = is3D ? 58 : 0; satelliteCamera = .camera(camera) }
    }
    private func savePhoto(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let size = CGSize(width: 160, height: 160)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            let scale = max(160 / image.size.width, 160 / image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            image.draw(in: CGRect(x: (160 - width) / 2, y: (160 - height) / 2, width: width, height: height))
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.65) { avatar = jpeg; UserDefaults.standard.set(jpeg, forKey: "avatar"); await api.action("profile", ["name": name, "avatar": jpeg.base64EncodedString()]) }
    }
    private var settingsView: some View {
                NavigationStack { Form {
                    Section("Твой профиль") { TextField("Имя", text: $name); PhotosPicker(selection: $photo, matching: .images) { Label("Выбрать аватарку", systemImage: "photo") } }
                    Section("Подключение") {
                        DisclosureGroup("Адрес сервера") { TextField("HTTPS-адрес", text: $api.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }
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
                    Section("О приложении") { Text("Рядом · 0.2"); Text("Виджет показывает последнюю позицию, полученную приложением. iOS определяет время его обновления.") }
                }.navigationTitle("Настройки").toolbar { Button("Готово") { settings = false } } }
    }
}
struct ProfileBubble: View {
    let data: Data?
    let name: String
    let color: Color
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.39, weight: .semibold, design: .rounded)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(color) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}
