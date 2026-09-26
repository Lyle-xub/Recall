import SwiftUI
import Charts

private enum UsageCategory:String,CaseIterable {
    case productivity = "Productivity", communication = "Communication", creativity = "Creativity"
    case tools = "Utilities", entertainment = "Entertainment", education = "Education", other = "Other", privateActivity = "Private activity"
    var color:Color { switch self {
        case .productivity: Color(red:0.25,green:0.57,blue:0.94)
        case .communication: Color(red:0.25,green:0.74,blue:0.76)
        case .creativity: Color(red:0.64,green:0.53,blue:0.85)
        case .tools: Color(red:0.43,green:0.65,blue:0.89)
        case .entertainment: Color(red:0.97,green:0.65,blue:0.40)
        case .education: Color(red:0.49,green:0.75,blue:0.57)
        case .other: Color(red:0.62,green:0.68,blue:0.75)
        case .privateActivity: Color(red:0.73,green:0.74,blue:0.77)
    } }
    @MainActor private static var cache:[String:Self] = [:]
    @MainActor static func resolve(_ app:AppUsageIdentity) -> Self {
        if app.kind == .excluded { return .privateActivity }
        if let cached = cache[app.bundleID] { return cached }
        let category = NSWorkspace.shared.urlForApplication(withBundleIdentifier:app.bundleID)
            .flatMap { Bundle(url:$0)?.object(forInfoDictionaryKey:"LSApplicationCategoryType") as? String } ?? ""
        let value:Self
        if category.contains("productivity") || category.contains("business") || category.contains("finance") { value = .productivity }
        else if category.contains("social") { value = .communication }
        else if ["design","photography","music","video","graphics"].contains(where:category.contains) { value = .creativity }
        else if category.contains("utilities") || category.contains("developer") { value = .tools }
        else if category.contains("games") || category.contains("entertainment") { value = .entertainment }
        else if category.contains("education") || category.contains("reference") { value = .education }
        else { value = .other }
        cache[app.bundleID] = value; return value
    }
}

struct AppUsageView: View {
    @ObservedObject var model:AppModel
    @State private var date = Calendar.current.startOfDay(for:Date())
    @State private var report:UsageReport?
    @State private var search = ""
    @State private var error:String?
    @State private var loading = true
    @State private var refresh = 0
    @State private var calendarOpen = false
    @Environment(\.dismiss) private var dismiss
    private let cardColor = Color(red:0.97,green:0.978,blue:0.989)
    private var today:Date { Calendar.current.startOfDay(for:Date()) }
    private var isToday:Bool { Calendar.current.isDateInToday(date) }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Image(systemName:"chart.bar.xaxis").font(.system(size:25)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:4) {
                    Text("App usage").font(.system(size:24,weight:.semibold,design:.rounded))
                    Label("This Mac",systemImage:"desktopcomputer").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:44,height:44).liquidGlass(radius:22) }
                    .buttonStyle(.plain).accessibilityLabel("Close app usage")
            }.padding(24)
            ScrollView(showsIndicators:false) {
                VStack(spacing:18) {
                    if let report,Calendar.current.isDate(report.day.start,inSameDayAs:date) {
                        overview(report)
                        applicationList(report)
                        Text("Foreground app time recorded by Recall. Paused recording and unavailable screen time are excluded. Private apps appear only as Private activity.\(report.firstRecorded.map { " History begins " + $0.recallFormatted(date:.abbreviated,time:.shortened) + "." } ?? "")")
                            .font(.system(size:11)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                    } else if error == nil { ProgressView("Loading app activity…").frame(maxWidth:.infinity,minHeight:300) }
                    if let error {
                        VStack(spacing:10) {Text(error).foregroundStyle(.secondary);Button("Try again") { refresh += 1 }}.padding()
                    }
                }.padding(.horizontal,24).padding(.bottom,24)
            }.scrollIndicators(.never)
        }
        .frame(width:760,height:min(860,max(560,(model.window?.screen?.visibleFrame.height ?? 940)-80)))
        .background(.white).presentationBackground(.white).preferredColorScheme(.light)
        .font(.system(size:13)).controlSize(.large)
        .task(id:"\(date.timeIntervalSince1970)-\(refresh)") {
            loading = true; error = nil
            let root = model.store.root, selectedDate = date
            repeat {
                let work = Task.detached(priority:.utility) { try UsageReport.load(root:root,date:selectedDate) }
                do {
                    let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                    guard !Task.isCancelled else { return }; report = result; loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false }; return }
                do { try await Task.sleep(for:.seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .onExitCommand { dismiss() }
    }
    private func overview(_ report:UsageReport) -> some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("Usage time").font(.system(size:14,weight:.medium)).foregroundStyle(.secondary)
                    Text(UsageReport.duration(report.total)).font(.system(size:34,weight:.semibold,design:.rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment:.trailing,spacing:8) {
                    Button { calendarOpen.toggle() } label: {
                        HStack(spacing:8) {
                            Image(systemName:"calendar").foregroundStyle(.blue)
                            Text(date.recallFormatted(.dateTime.year().month(.abbreviated).day())).fontWeight(.medium)
                            Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                        }.font(.system(size:12)).padding(.horizontal,13).frame(height:38)
                            .background(.white,in:Capsule()).overlay(Capsule().strokeBorder(.blue.opacity(0.08)))
                    }.buttonStyle(.plain).accessibilityLabel("Choose usage date")
                        .popover(isPresented:$calendarOpen,arrowEdge:.bottom) {
                            UsageCalendar(selection:date) { selected in calendarOpen = false; date = selected }
                                .presentationBackground(.white).preferredColorScheme(.light)
                        }
                    HStack(spacing:4) {
                        navigationButton("chevron.left",label:"Previous day",disabled:false) { changeDay(-1) }
                        Button("Today") { date = today }.buttonStyle(.plain).frame(width:62,height:36).background(.white,in:RoundedRectangle(cornerRadius:10))
                        navigationButton("chevron.right",label:"Next day",disabled:isToday) { changeDay(1) }
                    }
                }
            }
            VStack(alignment:.leading,spacing:9) {
                HStack {Text("Week · hours").font(.system(size:12,weight:.medium));Spacer();Text("Daily average · \(UsageReport.duration(report.dailyAverage))").font(.system(size:11)).foregroundStyle(.secondary).help("Average across days with recorded activity")}
                weekChart(report).frame(height:122)
            }
            Divider().opacity(0.45)
            VStack(alignment:.leading,spacing:10) {
                Text("Hourly activity · minutes").font(.system(size:12,weight:.medium))
                hourChart(report).frame(height:112)
            }
            let categories = totals(report.apps,identities:report.identities)
            if !categories.isEmpty {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:140),alignment:.leading)],alignment:.leading,spacing:12) {
                    ForEach(categories,id:\.0) { category,seconds in
                        HStack(alignment:.top,spacing:7) {
                            RoundedRectangle(cornerRadius:3).fill(category.color).frame(width:9,height:9).padding(.top,3)
                            VStack(alignment:.leading,spacing:4) {Text(category.rawValue).foregroundStyle(.secondary);Text(UsageReport.duration(seconds)).fontWeight(.medium)}.font(.system(size:11))
                        }
                    }
                }
            }
        }.padding(22).background(cardColor,in:RoundedRectangle(cornerRadius:22))
    }
    private func weekBar(_ bucket:UsageBucket,category:UsageCategory,seconds:Double) -> some ChartContent {
        let color:Color = Calendar.current.isDate(bucket.start,inSameDayAs:date) ? category.color:Color(red:0.78,green:0.81,blue:0.85)
        let label:String = bucket.start.recallFormatted(.dateTime.weekday().month().day()) + ", " + category.rawValue
        return BarMark(x:.value("Day",bucket.start,unit:.day),y:.value("Hours",seconds/3600))
            .foregroundStyle(color).cornerRadius(3)
            .accessibilityLabel(label).accessibilityValue(UsageReport.duration(seconds))
    }
    @ChartContentBuilder private func weekMarks(_ report:UsageReport) -> some ChartContent {
        ForEach(report.days) { bucket in
            ForEach(categoryBuckets(bucket,identities:report.identities),id:\.0) { category,seconds in
                weekBar(bucket,category:category,seconds:seconds)
            }
        }
        if report.dailyAverage > 0 {
            RuleMark(y:.value("Daily average",report.dailyAverage/3600)).lineStyle(StrokeStyle(lineWidth:1,dash:[4,4])).foregroundStyle(.green.opacity(0.65))
        }
    }
    private func weekChart(_ report:UsageReport) -> some View {
        let maximum:Double = max(1,(report.days.map(\.seconds).max() ?? 0)/3600*1.18)
        return Chart { weekMarks(report) }.chartLegend(.hidden).chartXScale(domain:report.week.start...report.week.end)
            .chartYScale(domain:0...maximum)
            .chartXAxis { AxisMarks(values:.stride(by:.day)) { AxisValueLabel(format:.dateTime.weekday(.narrow));AxisGridLine().foregroundStyle(.gray.opacity(0.1)) } }
            .chartYAxis { AxisMarks(position:.trailing,values:.automatic(desiredCount:3)) { AxisValueLabel();AxisGridLine().foregroundStyle(.gray.opacity(0.13)) } }
            .chartOverlay { proxy in GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                    guard let plot = proxy.plotFrame else { return }
                    let x = point.x-geometry[plot].origin.x
                    if let day:Date = proxy.value(atX:x),day >= report.week.start,day < report.week.end,day <= Date() { date = Calendar.current.startOfDay(for:day) }
                }
            } }
    }
    private func hourChart(_ report:UsageReport) -> some View {
        Chart {
            ForEach(report.hours) { bucket in
                ForEach(categoryBuckets(bucket,identities:report.identities),id:\.0) { category,seconds in
                    BarMark(x:.value("Hour",bucket.start,unit:.hour),y:.value("Minutes",seconds/60))
                        .foregroundStyle(category.color).cornerRadius(2)
                        .accessibilityLabel(bucket.start.recallFormatted(.dateTime.hour()) + ", " + category.rawValue)
                        .accessibilityValue(UsageReport.duration(seconds))
                }
            }
        }.chartLegend(.hidden).chartXScale(domain:report.day.start...report.day.end).chartYScale(domain:0...60)
            .chartXAxis { AxisMarks(values:.stride(by:.hour,count:6)) { AxisValueLabel(format:.dateTime.hour());AxisGridLine().foregroundStyle(.gray.opacity(0.1)) } }
            .chartYAxis { AxisMarks(position:.trailing,values:[0,30,60]) { AxisValueLabel();AxisGridLine().foregroundStyle(.gray.opacity(0.13)) } }
    }
    private func applicationList(_ report:UsageReport) -> some View {
        VStack(spacing:0) {
            HStack {
                Text("Apps").font(.system(size:15,weight:.semibold));Spacer()
                HStack(spacing:7) {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Search apps",text:$search).textFieldStyle(.plain)}
                    .padding(9).frame(width:210).background(.white,in:RoundedRectangle(cornerRadius:10))
            }.padding(.bottom,16)
            HStack {Text("Application");Spacer();Text("Time")}.font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.bottom,10)
            Divider()
            HStack {Label("Total usage",systemImage:"square.stack.3d.up.fill");Spacer();Text(UsageReport.duration(report.total)).monospacedDigit()}.fontWeight(.semibold).padding(.vertical,14)
            let filtered = report.apps.filter { search.isEmpty || $0.app.name.localizedStandardContains(search) }
            ForEach(filtered) { app in
                Divider().opacity(0.5)
                HStack(spacing:12) {
                    if app.app.kind == .excluded { Image(systemName:"lock.shield").foregroundStyle(.secondary).frame(width:30,height:30) }
                    else { AppBadge(name:app.app.name,bundleID:app.app.bundleID,size:30) }
                    VStack(alignment:.leading,spacing:4) {Text(app.app.name).lineLimit(1);Text(UsageCategory.resolve(app.app).rawValue).font(.system(size:10)).foregroundStyle(.secondary)}
                    Spacer()
                    GeometryReader { geometry in
                        Capsule().fill(.primary.opacity(0.045))
                        Capsule().fill(UsageCategory.resolve(app.app).color).frame(width:max(3,geometry.size.width*app.seconds/max(1,report.apps.first?.seconds ?? 1)))
                    }.frame(width:110,height:5).accessibilityHidden(true)
                    Text(UsageReport.duration(app.seconds)).monospacedDigit().frame(width:105,alignment:.trailing)
                }.padding(.vertical,12)
            }
            if filtered.isEmpty {
                VStack(spacing:8) {
                    Image(systemName:search.isEmpty ? "clock":"magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "No activity recorded on this day":"No matching apps").foregroundStyle(.secondary)
                    if search.isEmpty,isToday,!model.recording { Button("Start recording") { model.toggleRecording() }.disabled(model.working) }
                }.frame(maxWidth:.infinity).padding(24)
            }
        }.padding(22).background(cardColor,in:RoundedRectangle(cornerRadius:22))
    }
    private func changeDay(_ delta:Int) { if let next = Calendar.current.date(byAdding:.day,value:delta,to:date) { date = min(today,next) } }
    private func navigationButton(_ symbol:String,label:String,disabled:Bool,action:@escaping()->Void) -> some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.semibold)).frame(width:36,height:36).background(.white,in:RoundedRectangle(cornerRadius:10)) }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }
    private func categoryBuckets(_ bucket:UsageBucket,identities:[String:AppUsageIdentity]) -> [(UsageCategory,Double)] {
        var values:[UsageCategory:Double] = [:]
        for (key,seconds) in bucket.apps { if let app = identities[key] { values[UsageCategory.resolve(app),default:0] += seconds } }
        return UsageCategory.allCases.compactMap { category in values[category].map { (category,$0) } }
    }
    private func totals(_ apps:[UsageAppTotal],identities:[String:AppUsageIdentity]) -> [(UsageCategory,Double)] {
        var values:[UsageCategory:Double] = [:]
        for app in apps { values[UsageCategory.resolve(app.app),default:0] += app.seconds }
        return values.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue:$0.value > $1.value }.map { ($0.key,$0.value) }
    }
}
