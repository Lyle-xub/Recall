import SwiftUI
import Charts

struct AppUsageView: View {
    @ObservedObject var model:AppModel
    @StateObject private var activity = UsageReportState()
    @State private var selectedCategory:UsageCategory?
    @State private var search = ""
    @State private var refresh = 0
    @State private var calendarOpen = false
    @Environment(\.dismiss) private var dismiss
    private let cardColor = Color(red:0.97,green:0.978,blue:0.989)
    private var date:Date { activity.selectedDay }
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
                if activity.loading { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:44,height:44).liquidGlass(radius:22) }
                    .buttonStyle(.plain).accessibilityLabel("Close app usage")
            }.padding(24)
            ScrollView(showsIndicators:false) {
                VStack(spacing:18) {
                    let report = activity.report ?? UsageReport.build([],date:date)
                    overview(report)
                    applicationList(report)
                    Text("Foreground app time recorded by Recall. Paused recording and unavailable screen time are excluded. Calendar dots mark days with app usage activity, including private activity. Private apps appear only as Private activity.\(report.firstRecorded.map { " History begins " + $0.recallFormatted(date:.abbreviated,time:.shortened) + "." } ?? "")")
                        .font(.system(size:11)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.horizontal,24).padding(.bottom,24)
            }.scrollIndicators(.never)
        }
        .frame(width:760,height:min(860,max(560,(model.window?.screen?.visibleFrame.height ?? 940)-80)))
        .background(.white).presentationBackground(.white).preferredColorScheme(.light)
        .font(.system(size:13)).controlSize(.large)
        .task(id:"\(date.timeIntervalSince1970)-\(refresh)") {
            let root = model.store.root,calendar = Calendar.current
            repeat {
                await activity.load { day in try await UsageDataSource.shared.report(root:root,date:day,calendar:calendar) }
                guard !Task.isCancelled else { return }
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
                    Text(activity.report == nil ? "—":UsageReport.duration(report.total)).font(.system(size:34,weight:.semibold,design:.rounded)).monospacedDigit()
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
                            UsageCalendar(selection:date,root:model.store.root) { selected in calendarOpen = false; activity.select(selected) }
                                .presentationBackground(.white).preferredColorScheme(.light)
                        }
                    HStack(spacing:4) {
                        navigationButton("chevron.left",label:"Previous day",disabled:false) { changeDay(-1) }
                        Text(UsageDateLabel.navigation(date)).font(.system(size:12,weight:.medium)).frame(width:112,height:36)
                            .accessibilityLabel("Selected date: " + UsageDateLabel.navigation(date))
                        navigationButton("chevron.right",label:"Next day",disabled:isToday) { changeDay(1) }
                        Button("Today") { activity.select(today) }.buttonStyle(.plain).font(.system(size:11,weight:.medium))
                            .foregroundStyle(.blue).frame(width:44,height:36).disabled(isToday).help("Return to today")
                            .accessibilityLabel("Return to today")
                    }
                }
            }
            reportStatus(report)
            VStack(alignment:.leading,spacing:9) {
                HStack {
                    Text("Week · hours").font(.system(size:12,weight:.medium))
                    Picker("Chart category",selection:$selectedCategory) {
                        Text("All categories").tag(Optional<UsageCategory>.none)
                        ForEach(UsageCategory.allCases,id:\.self) { category in Label(category.rawValue,systemImage:category.symbol).tag(Optional(category)) }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width:155).accessibilityLabel("Chart category")
                    Spacer()
                    Text("Daily average · \(UsageReport.duration(chartDailyAverage(report)))").font(.system(size:11)).foregroundStyle(.secondary).help("Average across days with recorded activity")
                }
                weekChart(report).frame(height:122)
            }
            Divider().opacity(0.45)
            VStack(alignment:.leading,spacing:10) {
                Text("Hourly activity · minutes").font(.system(size:12,weight:.medium))
                hourChart(report).frame(height:112)
            }
            let categories = totals(report.apps,identities:report.identities)
            Group {
                if !categories.isEmpty {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:140),alignment:.leading)],alignment:.leading,spacing:12) {
                        ForEach(categories,id:\.0) { category,seconds in
                            HStack(alignment:.top,spacing:7) {
                                Image(systemName:category.symbol).foregroundStyle(category.color).font(.system(size:12)).frame(width:16).padding(.top,2).accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:4) {Text(category.rawValue).foregroundStyle(.secondary);Text(UsageReport.duration(seconds)).fontWeight(.medium)}.font(.system(size:11))
                            }
                        }
                    }
                } else {
                    Text(activity.report == nil ? "Loading category totals…":"No categorized activity on this day")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,minHeight:80,alignment:.topLeading)
        }.padding(22).background(cardColor,in:RoundedRectangle(cornerRadius:22))
    }
    private func reportStatus(_ report:UsageReport) -> some View {
        HStack(spacing:6) {
            if let error = activity.error {
                Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                Text("Could not load " + UsageDateLabel.absolute(date)).help(error)
                if activity.report != nil { Text("· Showing " + UsageDateLabel.absolute(report.day.start)) }
                Spacer(minLength:0)
                Button("Try again") { refresh += 1 }.buttonStyle(.plain).foregroundStyle(.blue)
            } else if activity.loading {
                Text("Loading " + UsageDateLabel.absolute(date) + "…")
                if activity.report != nil { Text("· Showing " + UsageDateLabel.absolute(report.day.start)) }
                Spacer(minLength:0)
            } else {
                Text("Showing " + UsageDateLabel.absolute(report.day.start))
                Spacer(minLength:0)
            }
        }.font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).frame(height:18)
            .accessibilityElement(children:.combine)
    }
    private func chartDailyAverage(_ report:UsageReport) -> Double {
        let recorded = report.days.filter { $0.seconds > 0 }
        guard !recorded.isEmpty else { return 0 }
        return recorded.reduce(0) { total,day in total + categoryBuckets(day,identities:report.identities).reduce(0) { $0+$1.1 } } / Double(recorded.count)
    }
    private func weekBar(_ bucket:UsageBucket,category:UsageCategory,seconds:Double) -> some ChartContent {
        let label:String = bucket.start.recallFormatted(.dateTime.weekday().month().day()) + ", " + category.rawValue
        return BarMark(x:.value("Day",bucket.start,unit:.day),y:.value("Hours",seconds/3600))
            .foregroundStyle(category.color).cornerRadius(3)
            .accessibilityLabel(label).accessibilityValue(UsageReport.duration(seconds))
    }
    @ChartContentBuilder private func weekMarks(_ report:UsageReport) -> some ChartContent {
        ForEach(report.days) { bucket in
            ForEach(categoryBuckets(bucket,identities:report.identities),id:\.0) { category,seconds in
                weekBar(bucket,category:category,seconds:seconds)
            }
        }
        if chartDailyAverage(report) > 0 {
            RuleMark(y:.value("Daily average",chartDailyAverage(report)/3600)).lineStyle(StrokeStyle(lineWidth:1,dash:[4,4])).foregroundStyle(.green.opacity(0.65))
        }
    }
    private func weekChart(_ report:UsageReport) -> some View {
        let maximum:Double = max(1,(report.days.map(\.seconds).max() ?? 0)/3600*1.18)
        return Chart { weekMarks(report) }.chartLegend(.hidden).chartXScale(domain:report.week.start...report.week.end)
            .chartYScale(domain:0...maximum)
            .chartXAxis {
                AxisMarks(values:.stride(by:.day)) { value in
                    AxisValueLabel {
                        if let day = value.as(Date.self) {
                            let selected = Calendar.current.isDate(day,inSameDayAs:report.day.start)
                            Text(day.recallFormatted(.dateTime.weekday(.narrow)))
                                .font(.system(size:10,weight:selected ? .bold:.regular))
                                .foregroundStyle(selected ? Color.white:Color.secondary)
                                .frame(width:20,height:20).background(selected ? Color.primary.opacity(0.8):Color.clear,in:Circle())
                                .accessibilityLabel(day.recallFormatted(date:.complete,time:.omitted) + (selected ? ", selected usage day":""))
                        }
                    }
                    AxisGridLine().foregroundStyle(.gray.opacity(0.1))
                }
            }
            .chartYAxis { AxisMarks(position:.trailing,values:.automatic(desiredCount:3)) { AxisValueLabel();AxisGridLine().foregroundStyle(.gray.opacity(0.13)) } }
            .chartOverlay { proxy in GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                    guard let plot = proxy.plotFrame else { return }
                    let x = point.x-geometry[plot].origin.x
                    if let day:Date = proxy.value(atX:x),day >= report.week.start,day < report.week.end,day <= Date() { activity.select(day) }
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
            HStack {Label("Total usage",systemImage:"square.stack.3d.up.fill");Spacer();Text(activity.report == nil ? "—":UsageReport.duration(report.total)).monospacedDigit()}.fontWeight(.semibold).padding(.vertical,14)
            let filtered = report.apps.filter { search.isEmpty || $0.app.name.localizedStandardContains(search) }
            ForEach(filtered) { app in
                Divider().opacity(0.5)
                HStack(spacing:12) {
                    if app.app.kind == .excluded { Image(systemName:"lock.shield").foregroundStyle(.secondary).frame(width:30,height:30) }
                    else { AppBadge(name:app.app.name,bundleID:app.app.bundleID,size:30) }
                    VStack(alignment:.leading,spacing:4) {Text(app.app.name).lineLimit(1);Label(UsageCategory.resolve(app.app).rawValue,systemImage:UsageCategory.resolve(app.app).symbol).font(.system(size:10)).foregroundStyle(.secondary)}
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
                    Text(activity.report == nil ? (activity.loading ? "Loading app activity…":"App activity unavailable"):(search.isEmpty ? "No activity recorded on this day":"No matching apps")).foregroundStyle(.secondary)
                    if activity.report != nil,search.isEmpty,Calendar.current.isDateInToday(report.day.start),!model.recording { Button("Start recording") { model.toggleRecording() }.disabled(model.working) }
                }.frame(maxWidth:.infinity).padding(24)
            }
        }.padding(22).background(cardColor,in:RoundedRectangle(cornerRadius:22))
    }
    private func changeDay(_ delta:Int) { if let next = Calendar.current.date(byAdding:.day,value:delta,to:date) { activity.select(min(today,next)) } }
    private func navigationButton(_ symbol:String,label:String,disabled:Bool,action:@escaping()->Void) -> some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.semibold)).frame(width:36,height:36).background(.white,in:RoundedRectangle(cornerRadius:10)) }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }
    private func categoryBuckets(_ bucket:UsageBucket,identities:[String:AppUsageIdentity]) -> [(UsageCategory,Double)] {
        var values:[UsageCategory:Double] = [:]
        for (key,seconds) in bucket.apps { if let app = identities[key] { values[UsageCategory.resolve(app),default:0] += seconds } }
        return UsageCategory.allCases.filter { selectedCategory == nil || $0 == selectedCategory }.compactMap { category in values[category].map { (category,$0) } }
    }
    private func totals(_ apps:[UsageAppTotal],identities:[String:AppUsageIdentity]) -> [(UsageCategory,Double)] {
        var values:[UsageCategory:Double] = [:]
        for app in apps { values[UsageCategory.resolve(app.app),default:0] += app.seconds }
        return values.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue:$0.value > $1.value }.map { ($0.key,$0.value) }
    }
}
