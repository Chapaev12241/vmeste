import SwiftUI
import WidgetKit
import CoreLocation
struct PairEntry: TimelineEntry { let date: Date; let state: PairState? }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PairEntry { PairEntry(date: Date(), state: nil) }
    func getSnapshot(in context: Context, completion: @escaping(PairEntry) -> Void) { completion(PairEntry(date: Date(), state: SharedStore.state)) }
    func getTimeline(in context: Context, completion: @escaping(Timeline<PairEntry>) -> Void) { completion(Timeline(entries: [PairEntry(date: Date(), state: SharedStore.state)], policy: .after(Date().addingTimeInterval(900)))) }
}
struct PairWidgetView: View {
    let entry: PairEntry
    private let accent = Color(red: 0.40, green: 0.34, blue: 0.90)
    private let coral = Color(red: 1, green: 0.49, blue: 0.40)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label("Рядом", systemImage: "heart.fill").font(.caption.bold()).foregroundStyle(accent); Spacer(); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
            if let partner = entry.state?.partner {
                HStack(spacing: 9) { avatar(partner); Text(partner.name).font(.headline).lineLimit(1) }
                if partner.paused { Label("На паузе", systemImage: "pause.fill").font(.caption).foregroundStyle(.secondary) }
                else if let timestamp = partner.updated, partner.location != nil {
                    Text(distanceText).font(.system(.title3, design: .rounded, weight: .semibold)).minimumScaleFactor(0.75).lineLimit(1)
                    HStack(spacing: 4) { Text("Обновлено"); Text(Date(timeIntervalSince1970: timestamp), style: .relative) }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else { Text("Ждём геопозицию").font(.caption).foregroundStyle(.secondary) }
            } else {
                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(coral)
                Text("Ваш мир на двоих").font(.headline)
                Text("Подключите пару").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).containerBackground(.fill.tertiary, for: .widget).widgetURL(URL(string: "ryadom://map"))
    }
    private var distanceText: String {
        guard let me = entry.state?.me, !me.paused, let own = me.location, let partner = entry.state?.partner?.location else { return "Позиция получена" }
        let distance = CLLocation(latitude: own.latitude, longitude: own.longitude).distance(from: CLLocation(latitude: partner.latitude, longitude: partner.longitude))
        return distance < 1000 ? "\(Int(distance)) м от тебя" : String(format: "%.1f км от тебя", distance / 1000)
    }
    @ViewBuilder private func avatar(_ person: Person) -> some View {
        if let data = person.avatar.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(Circle()) }
        else { Text(String(person.name.prefix(1)).uppercased()).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(coral, in: Circle()) }
    }
}
@main struct RyadomWidget: Widget {
    let kind = "RyadomPair"
    var body: some WidgetConfiguration { StaticConfiguration(kind: kind, provider: Provider()) { PairWidgetView(entry: $0) }.configurationDisplayName("Рядом").description("Последняя полученная позиция любимого человека").supportedFamilies([.systemSmall, .systemMedium]) }
}
