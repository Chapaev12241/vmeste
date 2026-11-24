import SwiftUI
import WidgetKit
struct PairEntry: TimelineEntry { let date: Date; let state: PairState? }
struct Provider: TimelineProvider {
    func placeholder(in context: Context)->PairEntry { PairEntry(date:Date(),state:nil) }
    func getSnapshot(in context: Context,completion:@escaping(PairEntry)->Void) { completion(PairEntry(date:Date(),state:SharedStore.state)) }
    func getTimeline(in context: Context,completion:@escaping(Timeline<PairEntry>)->Void) { completion(Timeline(entries:[PairEntry(date:Date(),state:SharedStore.state)],policy:.after(Date().addingTimeInterval(900)))) }
}
struct PairWidgetView: View {
    let entry: PairEntry
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Label("РЯДОМ",systemImage:"heart.fill").font(.caption.bold()).foregroundStyle(.mint)
            if let partner=entry.state?.partner {
                HStack {
                    if let encoded=partner.avatar,let data=Data(base64Encoded:encoded),let image=UIImage(data:data) { Image(uiImage:image).resizable().scaledToFill().frame(width:32,height:32).clipShape(Circle()) }
                    Text(partner.name).font(.headline)
                }
                if partner.paused { Text("Геопозиция на паузе").font(.caption) }
                else if let position=partner.location,let timestamp=partner.updated {
                    Text(String(format:"%.3f, %.3f",position.latitude,position.longitude)).font(.caption.monospaced())
                    Text("Последняя позиция").font(.caption2)
                    Text(Date(timeIntervalSince1970:timestamp),style:.relative).font(.caption2)
                } else { Text("Ожидаем геопозицию").font(.caption) }
            } else { Text("Подключите пару в приложении").font(.subheadline) }
        }.frame(maxWidth:.infinity,alignment:.leading).containerBackground(.fill.tertiary,for:.widget).widgetURL(URL(string:"ryadom://map"))
    }
}
@main struct RyadomWidget: Widget {
    let kind="RyadomPair"
    var body: some WidgetConfiguration { StaticConfiguration(kind:kind,provider:Provider()) { PairWidgetView(entry:$0) }.configurationDisplayName("Рядом").description("Последняя полученная позиция любимого человека").supportedFamilies([.systemSmall,.systemMedium]) }
}
