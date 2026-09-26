import SwiftUI

struct UsageCalendar:View {
    let selection:Date
    let choose:(Date)->Void
    @State private var month:Date
    private let calendar:Calendar = {
        var value = Calendar.current; value.locale = RecallLanguage.locale; return value
    }()
    private var today:Date { calendar.startOfDay(for:Date()) }
    init(selection:Date,choose:@escaping(Date)->Void) {
        self.selection = selection; self.choose = choose
        _month = State(initialValue:Calendar.current.dateInterval(of:.month,for:selection)!.start)
    }
    private var days:[Date?] {
        let start = calendar.dateInterval(of:.month,for:month)!.start
        let offset = (calendar.component(.weekday,from:start)-calendar.firstWeekday+7)%7
        let count = calendar.range(of:.day,in:.month,for:month)!.count
        return (0..<42).map { index in
            guard index >= offset,index < offset+count else { return nil }
            return calendar.date(byAdding:.day,value:index-offset,to:start)
        }
    }
    private var weekdays:[String] {
        let labels = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { labels[($0+calendar.firstWeekday-1)%7] }
    }
    var body:some View {
        VStack(spacing:16) {
            HStack {
                Text(month.recallFormatted(.dateTime.year().month(.wide))).font(.system(size:15,weight:.semibold,design:.rounded))
                Spacer()
                monthButton("chevron.left",label:"Previous month") { move(-1) }
                monthButton("chevron.right",label:"Next month") { move(1) }
                    .disabled(calendar.isDate(month,equalTo:today,toGranularity:.month))
            }
            VStack(spacing:5) {
                HStack(spacing:2) { ForEach(weekdays.indices,id:\.self) { index in Text(weekdays[index]).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary).frame(width:36,height:22) } }
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(36),spacing:2),count:7),spacing:3) {
                    ForEach(days.indices,id:\.self) { index in
                        if let day = days[index] {
                            let selected = calendar.isDate(day,inSameDayAs:selection), isToday = calendar.isDateInToday(day)
                            Button { choose(day) } label: {
                                Text("\(calendar.component(.day,from:day))").font(.system(size:12,weight:selected || isToday ? .semibold:.regular)).monospacedDigit()
                                    .foregroundStyle(selected ? .white:day > today ? Color.secondary.opacity(0.4):.primary)
                                    .frame(width:36,height:36).background(selected ? Color.blue:.clear,in:Circle())
                                    .overlay(Circle().strokeBorder(isToday && !selected ? Color.blue.opacity(0.45):.clear))
                                    .contentShape(Circle())
                            }.buttonStyle(.plain).disabled(day > today)
                                .accessibilityLabel(day.recallFormatted(date:.complete,time:.omitted))
                                .accessibilityAddTraits(selected ? .isSelected:[])
                        } else { Color.clear.frame(width:36,height:36).accessibilityHidden(true) }
                    }
                }
            }
            Divider().opacity(0.45)
            HStack(spacing:8) {
                quickDate("Today",date:today)
                quickDate("Yesterday",date:calendar.date(byAdding:.day,value:-1,to:today)!)
            }
        }.padding(18).frame(width:300).background(.white)
    }
    private func move(_ delta:Int) { month = calendar.date(byAdding:.month,value:delta,to:month)! }
    private func monthButton(_ symbol:String,label:String,action:@escaping()->Void)->some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:11,weight:.semibold)).frame(width:32,height:32).background(Color.blue.opacity(0.055),in:Circle()) }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func quickDate(_ label:String,date:Date)->some View {
        Button { choose(date) } label: { Text(label).font(.system(size:12,weight:.medium)).frame(maxWidth:.infinity).frame(height:34).background(Color.blue.opacity(0.06),in:Capsule()).foregroundStyle(.blue) }.buttonStyle(.plain)
    }
}
