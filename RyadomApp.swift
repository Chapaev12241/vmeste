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
    @Published var status = "Геопозиция выключена"
    @Published var enabled = false
    @Published var locating = false
    @Published var authorization = CLAuthorizationStatus.notDetermined
    private var foreground = true
    private var monitoring = false
    private var standaloneRequest = false
    private var lastAttempt = Date.distantPast
    private var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    override init() {
        super.init()
        foreground = UIApplication.shared.applicationState != .background
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.pausesLocationUpdatesAutomatically = true
        authorization = manager.authorizationStatus
        enabled = UserDefaults.standard.bool(forKey: "sharingEnabled")
        if enabled { start() }
    }
    var frequentBackground: Bool { UserDefaults.standard.object(forKey: "frequentBackground") as? Bool ?? true }
    var backgroundContinuous: Bool { enabled && frequentBackground && authorization == .authorizedAlways }
    private func applySamplingProfile() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let accuracy: CLLocationAccuracy = foreground ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        let distance: CLLocationDistance = foreground ? 25 : lowPower ? 100 : (location?.speed ?? 0) >= 8 ? 75 : 50
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        if manager.distanceFilter != distance { manager.distanceFilter = distance }
        manager.activityType = .other
        // Explicitly enabled background tracking must not get stuck in an automatic pause.
        manager.pausesLocationUpdatesAutomatically = foreground || !backgroundContinuous
        manager.allowsBackgroundLocationUpdates = backgroundContinuous
        manager.showsBackgroundLocationIndicator = backgroundContinuous
    }
    func backgroundPreferenceChanged() { if enabled { start() } }
    var permissionBlocked: Bool { authorization == .denied || authorization == .restricted }
    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "sharingEnabled")
        if enabled { refreshNow() }
        else {
            stopLocally()
            Task { await API.shared.action("pause") }
        }
    }
    func stopLocally() {
        enabled = false; locating = false
        UserDefaults.standard.set(false, forKey: "sharingEnabled")
        retryTask?.cancel(); retryTask = nil
        manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false; manager.stopMonitoringSignificantLocationChanges()
        monitoring = false; status = "Геопозиция выключена"
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { if enabled { start(); publishIfNeeded(force: true) } }
        else { retryTask?.cancel(); retryTask = nil; if enabled { start() } else { manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false } }
    }
    func refreshNow() {
        if !enabled { enabled = true; UserDefaults.standard.set(true, forKey: "sharingEnabled") }
        lastAttempt = .distantPast
        if permissionBlocked { openSettings(); return }
        manager.stopUpdatingLocation()
        start()
        if let location, abs(location.timestamp.timeIntervalSinceNow) < 30 { publishIfNeeded(force: true) }
    }
    func locateOnly() {
        if enabled { refreshNow(); return }
        authorization = manager.authorizationStatus
        if permissionBlocked { openSettings(); return }
        standaloneRequest = true; locating = true
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { manager.requestLocation() }
    }
    func start() {
        guard enabled else { return }
        authorization = manager.authorizationStatus
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            if !monitoring, CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.startMonitoringSignificantLocationChanges(); monitoring = true
            }
            applySamplingProfile()
            if foreground {
                locating = location == nil; manager.startUpdatingLocation()
                status = location == nil ? "Ищем геопозицию…" : "Геопозиция включена"
                scheduleRetry()
            } else if backgroundContinuous {
                manager.startUpdatingLocation()
                status = "Частые фоновые обновления включены"
            } else {
                manager.stopUpdatingLocation()
                status = authorization == .authorizedAlways ? "Экономный режим в фоне" : "Для работы в фоне разрешите «Всегда»"
            }
        case .denied, .restricted:
            locating = false; manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false; manager.stopMonitoringSignificantLocationChanges(); monitoring = false; status = "Разрешите геопозицию в настройках iPhone"
        case .notDetermined:
            locating = true; status = "Ожидаем разрешения"; manager.requestWhenInUseAuthorization()
        @unknown default: status = "Проверьте разрешение геопозиции"
        }
    }
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                guard let self, self.enabled, self.foreground else { break }
                if self.location == nil || Date().timeIntervalSince(self.location!.timestamp) > 30 {
                    self.manager.stopUpdatingLocation()
                    self.manager.startUpdatingLocation()
                }
                self.publishIfNeeded(force: false)
            }
        }
    }
    private var minimumSendInterval: TimeInterval {
        if foreground { return 15 }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 60 }
        return (location?.speed ?? -1) >= 0 && (location?.speed ?? 0) < 0.5 ? 90 : 30
    }
    private func publishIfNeeded(force: Bool) {
        guard enabled, let location, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 180,
              uploadTask == nil, force || Date().timeIntervalSince(lastAttempt) >= minimumSendInterval else { return }
        lastAttempt = Date()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Send position", expirationHandler: nil)
        uploadTask = Task { [weak self] in
            await API.shared.publish(Coordinates(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy))
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            self?.uploadTask = nil
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if enabled { start() }
        else if standaloneRequest && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last(where: { $0.horizontalAccuracy >= 0 }), abs(latest.timestamp.timeIntervalSinceNow) < 180 else { return }
        location = latest; locating = false; standaloneRequest = false
        if enabled { applySamplingProfile() }
        status = !enabled ? "Геопозиция выключена" : foreground ? "Геопозиция включена" : backgroundContinuous ? "Частые фоновые обновления включены" : "Экономный режим в фоне"
        publishIfNeeded(force: false)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { authorization = manager.authorizationStatus; locating = false; status = "Разрешите геопозицию в настройках iPhone" }
        else { locating = enabled; status = "GPS пока недоступен — повторяем запрос"; if enabled && foreground { scheduleRetry() } }
    }
    func enableBackground() {
        if authorization == .notDetermined { refreshNow() }
        else if permissionBlocked { openSettings() }
        else { manager.requestAlwaysAuthorization() }
    }
    func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
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
    @State private var focusedOwn = false
    @AppStorage("passoMode") private var passoMode = "auto"
    @AppStorage("passoOwnerIsMe") private var passoOwnerIsMe = false
    @State private var previousPartnerSample: (CLLocationCoordinate2D, TimeInterval)?
    @State private var partnerDrivingUntil = Date.distantPast
    @State private var ownDrivingUntil = Date.distantPast
    @State private var partnerHeading: Double = 0
    @State private var satelliteCamera: MapCameraPosition = .camera(MapCamera(centerCoordinate: Home.yuzhny, distance: 1800, heading: -18, pitch: 58))
    private let accent = Color(red: 0.40, green: 0.34, blue: 0.90)
    private let coral = Color(red: 1, green: 0.49, blue: 0.40)
    private var people: [MapPerson] {
        var result: [MapPerson] = []
        if let own = position.location { result.append(MapPerson(id: "me", name: name, coordinate: own.coordinate, avatar: avatar, isMe: true, isDriving: ownerIsDriving && passoOwnerIsMe, heading: max(0, own.course))) }
        if let partner = api.state?.partner, !partner.paused, let point = partner.location {
            result.append(MapPerson(id: "partner", name: partner.name, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), avatar: partner.avatar.flatMap { Data(base64Encoded: $0) }, isMe: false, isDriving: ownerIsDriving && !passoOwnerIsMe, heading: partnerHeading))
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
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: phase) { _, phase in position.setForeground(phase == .active); if phase == .active { Task { do { try await api.connect() } catch { api.error = error.localizedDescription } } } }
        .onChange(of: position.location?.timestamp) { _, _ in
            if let location = position.location {
                if location.speed >= 4.5 { ownDrivingUntil = Date().addingTimeInterval(120) }
                if !focusedOwn { focusedOwn = true; focus(location.coordinate) }
            }
        }
        .onChange(of: api.state?.partner?.updated) { _, _ in updatePartnerMotion() }
        .onAppear { position.setForeground(phase == .active) }
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
                        if person.isDriving {
                            Image(uiImage: CarMarker.image(heading: person.heading)).resizable().frame(width: 76, height: 76).accessibilityLabel("Белая Passo — поездка девушки")
                        } else {
                            ProfileBubble(data: person.avatar, name: person.name, color: person.isMe ? accent : coral, size: 42)
                                .padding(4).background(.background, in: Circle()).shadow(color: .black.opacity(0.16), radius: 5, y: 3)
                        }
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
                    Button { if let own = position.location { focus(own.coordinate) }; position.locateOnly() } label: { Image(systemName: "location.fill").font(.system(size: 18, weight: .semibold)).frame(width: 46, height: 46).background(.regularMaterial, in: Circle()) }.accessibilityLabel("Определить мою геопозицию")
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
                        } else { Text(position.enabled ? position.status : "Подключитесь по одному коду").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { if position.permissionBlocked { position.openSettings() } else { position.toggle() } } label: {
                Image(systemName: position.permissionBlocked ? "location.slash.fill" : position.enabled ? "pause.fill" : "location.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(accent, in: Circle())
            }.accessibilityLabel(position.enabled ? "Приостановить мою геопозицию" : "Включить мою геопозицию")
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.4), lineWidth: 0.5)).shadow(color: .black.opacity(0.09), radius: 18, y: 6)
    }
    private var ownerIsDriving: Bool {
        if passoOwnerIsMe { return passoMode != "off" && position.enabled && position.location != nil && (passoMode == "trip" || Date() < ownDrivingUntil || (isTogether && Date() < partnerDrivingUntil)) }
        guard passoMode != "off", api.state?.partner?.paused == false, api.state?.partner?.location != nil else { return false }
        if passoMode == "trip" { return true }
        if Date() < partnerDrivingUntil { return true }
        if let own = position.location, let point = api.state?.partner?.location,
           own.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) < 120,
           Date() < ownDrivingUntil { return true }
        return false
    }
    private var isTogether: Bool {
        guard let own = position.location, let point = api.state?.partner?.location else { return false }
        return own.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) < 120
    }
    private func updatePartnerMotion() {
        guard let partner = api.state?.partner, !partner.paused, let point = partner.location, let timestamp = partner.updated else {
            previousPartnerSample = nil; partnerDrivingUntil = .distantPast; return
        }
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        defer { previousPartnerSample = (coordinate, timestamp) }
        guard let previous = previousPartnerSample else { return }
        let elapsed = timestamp - previous.1
        guard elapsed > 1, elapsed < 300 else { return }
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: CLLocation(latitude: previous.0.latitude, longitude: previous.0.longitude))
        let speed = distance / elapsed
        if speed >= 4.5 && speed < 70 && distance > max(20, point.accuracy * 0.6) { partnerDrivingUntil = Date().addingTimeInterval(120) }
        if distance > 10 {
            let lat1 = previous.0.latitude * .pi / 180, lat2 = coordinate.latitude * .pi / 180
            let delta = (coordinate.longitude - previous.0.longitude) * .pi / 180
            partnerHeading = atan2(sin(delta) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(delta)) * 180 / .pi
        }
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
        AppSettingsView(position: position, api: api, name: $name, photo: $photo, avatar: avatar, confirmUnpair: $confirmUnpair, confirmDelete: $confirmDelete)
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
