import SwiftUI
import PhotosUI
import UIKit

struct AppSettingsView: View {
    @ObservedObject var position: Position
    @ObservedObject var api: API
    @Binding var name: String
    @Binding var photo: PhotosPickerItem?
    let avatar: Data?
    @Binding var confirmUnpair: Bool
    @Binding var confirmDelete: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("passoMode") private var passoMode = "auto"
    @AppStorage("backgroundMode") private var backgroundMode = "balanced"
    @AppStorage("passoOwnerIsMe") private var passoOwnerIsMe = false
    @State private var code = ""
    @State private var connecting = false
    private let accent = Color(red: 0.40, green: 0.34, blue: 0.90)
    private let coral = Color(red: 1, green: 0.49, blue: 0.40)
    private var working: Bool { api.busy || connecting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionSummary
                    if let notice = api.notice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("Готово: \(notice)")
                    }
                    profileSection
                    locationSection
                    pairSection
                    carSection
                    serverSection
                    accountSection
                    Text("Рядом · 0.4.2\nВаш маленький мир на двоих")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.vertical, 12)
                }.padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }.fontWeight(.semibold).buttonStyle(.bordered).tint(accent)
                }
            }
            .tint(accent)
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: api.connected ? "checkmark.shield.fill" : "link.badge.plus")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 50, height: 50).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(api.connected ? "Связь с сервером установлена" : "Подключение не подтверждено").font(.headline)
                Text(api.state?.partner == nil ? "Подключите пару по одному коду" : "Вы в паре с \(api.state?.partner?.name ?? "партнёром")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if working { ProgressView().accessibilityLabel("Выполняется действие") }
        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var profileSection: some View {
        section("Твой профиль", icon: "person.crop.circle") {
            HStack(spacing: 14) {
                ProfileBubble(data: avatar, name: name, color: accent, size: 62)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Имя на карте").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("Как тебя зовут?", text: $name).font(.headline)
                        .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .submitLabel(.done).accessibilityLabel("Твоё имя на карте")
                }
            }
            PhotosPicker(selection: $photo, matching: .images) {
                actionLabel("Выбрать аватарку", icon: "photo.on.rectangle.angled")
            }.buttonStyle(SettingsActionStyle(tint: accent, filled: false)).accessibilityLabel("Выбрать фотографию для аватарки")
            action("Сохранить профиль", icon: "checkmark", disabled: working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task { await api.action("profile", ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "avatar": avatar?.base64EncodedString() as Any? ?? NSNull()]) }
            }
        }
    }

    private var locationSection: some View {
        section("Геопозиция", icon: "location.fill") {
            Toggle(isOn: Binding(get: { position.enabled }, set: { if $0 != position.enabled { position.toggle() } })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Делиться моей позицией").font(.subheadline.weight(.semibold))
                    Text(position.permissionBlocked ? "Нужно разрешение в настройках iPhone" : position.enabled ? "Партнёр может видеть тебя на карте" : "Передача координат выключена").font(.caption).foregroundStyle(.secondary)
                }
            }.tint(accent).padding(.vertical, 4).accessibilityLabel("Делиться моей геопозицией")
            Divider()
            HStack(alignment: .top, spacing: 9) {
                if position.locating || api.sending { ProgressView().scaleEffect(0.85) }
                else { Image(systemName: position.permissionBlocked ? "exclamationmark.triangle.fill" : "location.circle.fill").foregroundStyle(position.permissionBlocked ? Color.orange : accent) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(position.status).font(.subheadline.weight(.medium))
                    if api.sending { Text("Отправляем координаты партнёру…").font(.caption).foregroundStyle(.secondary) }
                    if let sent = api.lastUploadAt {
                        Text("Отправлено на сервер в \(sent.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let location = position.location {
                        Text("Точность ±\(Int(max(0, location.horizontalAccuracy))) м · обновлено в \(location.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            action(position.permissionBlocked ? "Разрешить в настройках iPhone" : "Получить и отправить позицию", icon: position.permissionBlocked ? "gearshape.fill" : "location.circle.fill") {
                if position.permissionBlocked { position.openSettings() } else { position.refreshNow(); api.notice = "Запросили свежую геопозицию" }
            }
            action("Разрешить обновления в фоне", icon: "moon.stars.fill", secondary: true) { position.enableBackground() }
            Text("Фоновые обновления").font(.subheadline.weight(.semibold))
            Picker("Режим фоновых обновлений", selection: $backgroundMode) {
                Text("Экономный").tag("economy")
                Text("Баланс").tag("balanced")
                Text("Частый").tag("frequent")
            }.pickerStyle(.segmented)
                .onChange(of: backgroundMode) { _, _ in position.backgroundPreferenceChanged() }
            Text(backgroundMode == "economy" ? "Больше экономии заряда. Координаты обновляются при существенном перемещении." : backgroundMode == "frequent" ? "Фильтр 15–25 м, отправка не чаще раза в 15 секунд. Выше точность и расход заряда." : "Фильтр 50–75 м, отправка не чаще раза в 30 секунд; стоя — реже. Умеренная точность и расход заряда.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairSection: some View {
        section("Вы вдвоём", icon: "heart.fill") {
            if let partner = api.state?.partner {
                HStack(spacing: 12) {
                    ProfileBubble(data: partner.avatar.flatMap { Data(base64Encoded: $0) }, name: partner.name, color: coral, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(partner.name).font(.headline)
                        Text(partner.paused ? "Геопозиция партнёра на паузе" : "Пара подключена").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }.padding(.bottom, 4)
                action("Отключить пару", icon: "person.2.slash", destructive: true, secondary: true, disabled: working) { confirmUnpair = true }
            } else {
                Text("Один из вас создаёт код, второй вводит его на своём телефоне.").font(.subheadline).foregroundStyle(.secondary)
                action("Создать код приглашения", icon: "plus.circle.fill", disabled: working) { Task { await api.action("invite") } }
                if let invite = api.invite {
                    VStack(spacing: 12) {
                        Text(invite).font(.system(size: 25, weight: .bold, design: .monospaced)).tracking(2).textSelection(.enabled).accessibilityLabel("Код приглашения: \(invite)")
                        Text("Код действует 10 минут").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { UIPasteboard.general.string = invite; api.notice = "Код скопирован" } label: { Label("Скопировать", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44) }
                                .buttonStyle(SettingsActionStyle(tint: accent, filled: false))
                            ShareLink(item: "Подключись ко мне в Рядом. Сервер: \(api.endpoint), код: \(invite) (10 минут)") {
                                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                            }.buttonStyle(SettingsActionStyle(tint: accent, filled: false)).accessibilityLabel("Поделиться приглашением")
                        }
                    }.padding(14).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                }
                Divider().padding(.vertical, 3)
                Text("Уже есть код?").font(.subheadline.weight(.semibold))
                TextField("Введи код партнёра", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                    .padding(14).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Код приглашения от партнёра")
                action("Подключиться к партнёру", icon: "link", disabled: working || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task { await api.action("join", ["code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]) }
                }
            }
        }
    }

    private var carSection: some View {
        section("Белая Passo", icon: "car.side.fill") {
            Picker("Где девушка?", selection: $passoOwnerIsMe) {
                Text("На втором телефоне").tag(false)
                Text("На этом телефоне").tag(true)
            }.pickerStyle(.menu).font(.subheadline.weight(.semibold))
                .accessibilityLabel("На каком телефоне находится девушка")
            Text("На телефоне девушки выбери «На этом телефоне». На твоём телефоне оставь «На втором телефоне», чтобы машина не появлялась, когда ты едешь один.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Машина появляется на метке девушки: когда она едет одна или вы едете вместе. Когда ты едешь один, твоя метка остаётся обычной.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Показывать машину", selection: $passoMode) {
                Text("Авто").tag("auto")
                Text("В поездке").tag("trip")
                Text("Выкл.").tag("off")
            }.pickerStyle(.segmented).accessibilityLabel("Режим машины на метке девушки")
            Text(passoMode == "auto" ? "Автоматический режим оценивает движение по GPS. Он может ошибаться; для остановок и поездки вместе можно включить «В поездке»." : passoMode == "trip" ? "Режим поездки включён вручную. Машина остаётся видимой и на остановках." : "На карте отображаются обычные аватарки.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var serverSection: some View {
        section("Связь", icon: "network") {
            action(connecting ? "Подключаемся…" : "Подключиться к серверу", icon: "antenna.radiowaves.left.and.right", disabled: working) {
                connecting = true; api.notice = nil
                Task {
                    defer { connecting = false }
                    do { try await api.connect(); api.notice = "Сервер подключён" }
                    catch { api.error = error.localizedDescription }
                }
            }
            action("Восстановить связь", icon: "arrow.triangle.2.circlepath", secondary: true, disabled: working) { Task { await api.reconnect() } }
            Text("Если после обновления позиция не отправляется, нажми «Восстановить связь», затем «Получить и отправить позицию».").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Адрес сервера") {
                TextField("HTTPS-адрес", text: $api.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12)).padding(.top, 8)
                Text("Рабочий адрес уже задан. Меняй его только при переносе сервера.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }.font(.subheadline)
        }
    }

    private var accountSection: some View {
        section("Аккаунт", icon: "person.crop.circle.badge.minus") {
            action("Удалить мой аккаунт", icon: "trash", destructive: true, secondary: true, disabled: working) { confirmDelete = true }
            Text("Удаление аккаунта отключит пару и удалит твои данные с сервера.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(accent)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22)
            Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
            Spacer(minLength: 3)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.65)
        }.frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 14).contentShape(Rectangle())
    }
    private func action(_ title: String, icon: String, destructive: Bool = false, secondary: Bool = false, disabled: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) { actionLabel(title, icon: icon) }
            .buttonStyle(SettingsActionStyle(tint: destructive ? .red : accent, filled: !secondary))
            .disabled(disabled).accessibilityLabel(title)
    }
}

private struct SettingsActionStyle: ButtonStyle {
    let tint: Color
    var filled = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? tint : tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(tint.opacity(filled ? 0 : 0.18), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
