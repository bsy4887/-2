import SwiftUI
import UserNotifications
import AVFoundation

// iOS 17 이상 · Xcode → Signing & Capabilities → + Capability → Background Modes → "Audio" 체크

// MARK: - Model

struct AlarmItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour = 7
    var minute = 0
    var label = ""
    var weekdays: Set<Int> = []      // 1=일 ... 7=토
    var snooze = true
    var isOn = true
    var fireDate: Date? = nil        // 반복 없는 알람이 울릴 시각 (울린 뒤 자동으로 끄기 위함)

    var repeatText: String {
        if weekdays.isEmpty { return "안 함" }
        if weekdays.count == 7 { return "매일" }
        if weekdays == [2, 3, 4, 5, 6] { return "주중" }
        if weekdays == [1, 7] { return "주말" }
        let n = ["일", "월", "화", "수", "목", "금", "토"]
        return "매주 " + weekdays.sorted().map { n[$0 - 1] }.joined(separator: ", ")
    }

    mutating func arm() {
        guard isOn, weekdays.isEmpty else { fireDate = nil; return }
        fireDate = Calendar.current.nextDate(after: Date(),
                                             matching: DateComponents(hour: hour, minute: minute),
                                             matchingPolicy: .nextTime)
    }
}

// MARK: - 알람음 생성 / 재생

enum Tone {
    // 코드로 알람음(WAV)을 만들어요. 별도 파일 필요 없음.
    static func wav(seconds: Double, silent: Bool) -> Data {
        let sr = 22050, n = Int(Double(sr) * seconds)
        var pcm = [Int16](repeating: 0, count: n)
        if !silent {
            for i in 0..<n {
                let t = Double(i) / Double(sr)
                let p = t.truncatingRemainder(dividingBy: 1.0)
                if p < 0.15 || (p > 0.25 && p < 0.40) || (p > 0.50 && p < 0.65) {
                    pcm[i] = Int16(sin(2 * Double.pi * 880 * t) * 12000)
                }
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(n * 2))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    // 알림용 29초짜리 알람음을 Library/Sounds에 저장 (알림 소리는 30초 이하만 가능)
    static func installSound() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("alarm.wav")
        if !FileManager.default.fileExists(atPath: f.path) { try? wav(seconds: 29, silent: false).write(to: f) }
    }
}

@MainActor
final class Ringer {
    static let shared = Ringer()
    private var player: AVAudioPlayer?

    // 백그라운드에서 앱이 살아 있도록 무음 재생 → 알람 시각에 무음 모드와 상관없이 소리 재생
    func keepAlive() { guard player == nil else { return }; play(Tone.wav(seconds: 5, silent: true), 0, mix: true) }
    func ring() { play(Tone.wav(seconds: 4, silent: false), 1, mix: false) }

    func stop() {
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(_ data: Data, _ volume: Float, mix: Bool) {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: mix ? [.mixWithOthers] : [])
            try s.setActive(true)
            player?.stop()
            player = try AVAudioPlayer(data: data)
            player?.numberOfLoops = -1
            player?.volume = volume
            player?.play()
        } catch {}
    }
}

// MARK: - Store

@MainActor
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()
    @Published var alarms: [AlarmItem] = [] { didSet { save(); reschedule() } }
    @Published var ringing: AlarmItem?

    private let key = "alarms"
    private var fired: [UUID: String] = [:]
    private var snoozes: [(AlarmItem, Date)] = []
    private var timer: Timer?

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([AlarmItem].self, from: d) { alarms = v }
        Tone.installSound()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var sorted: [AlarmItem] { alarms.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) } }

    func upsert(_ a: AlarmItem) {
        if let i = alarms.firstIndex(where: { $0.id == a.id }) { alarms[i] = a } else { alarms.append(a) }
    }

    func expireOneShots() {
        for i in alarms.indices {
            if let f = alarms[i].fireDate, f < Date() { alarms[i].isOn = false; alarms[i].fireDate = nil }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(alarms) { UserDefaults.standard.set(d, forKey: key) }
    }

    // MARK: 울림 (앱이 살아 있을 때: 정확한 시각에 직접 울림)

    private func tick() {
        guard ringing == nil else { return }
        let now = Date(), cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .weekday], from: now)
        let key = "\(cal.startOfDay(for: now))\(c.hour ?? 0):\(c.minute ?? 0)"
        for a in alarms where a.isOn && a.hour == c.hour && a.minute == c.minute
            && (a.weekdays.isEmpty || a.weekdays.contains(c.weekday ?? 0)) && fired[a.id] != key {
            fired[a.id] = key
            present(a)
            return
        }
        if let i = snoozes.firstIndex(where: { $0.1 <= now }) { present(snoozes[i].0) }
    }

    func present(_ a: AlarmItem) {
        guard ringing == nil else { return }
        snoozes.removeAll { $0.0.id == a.id }
        ringing = a
        cancelChain(a.id)
        Ringer.shared.ring()
    }

    func present(id: String) {
        if let u = UUID(uuidString: id), let a = alarms.first(where: { $0.id == u }) { present(a) }
    }

    func item(id: String) -> AlarmItem? {
        UUID(uuidString: id).flatMap { u in alarms.first { $0.id == u } }
    }

    func endRinging() {
        Ringer.shared.stop()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        ringing = nil
        expireOneShots()
        reschedule()
    }

    func snooze(_ a: AlarmItem, fromRinging: Bool = true) {
        snoozes.append((a, Date().addingTimeInterval(9 * 60)))
        let req = UNNotificationRequest(identifier: "snooze-\(UUID())", content: content(a),
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 9 * 60, repeats: false))
        UNUserNotificationCenter.current().add(req)
        cancelChain(a.id)
        if fromRinging { endRinging() } else { reschedule() }
    }

    func cancelChain(_ id: UUID) {
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { reqs in
            c.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("\(id)-x") })
        }
        c.removeAllDeliveredNotifications()
    }

    // MARK: 알림 예약 (앱이 꺼져 있을 때를 대비)
    // 기본 알림(반복) + 이후 30초 간격 3번 추가 알림 → 약 2분간 이어서 울림

    private func content(_ a: AlarmItem) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = a.label.isEmpty ? "알람" : a.label
        c.body = String(format: "%02d:%02d", a.hour, a.minute)
        c.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
        c.interruptionLevel = .timeSensitive
        c.categoryIdentifier = a.snooze ? "ALARM_SNOOZE" : "ALARM"
        c.userInfo = ["id": a.id.uuidString]
        return c
    }

    func reschedule() {
        let cal = Calendar.current
        var base: [UNNotificationRequest] = []
        var extra: [(Date, UNNotificationRequest)] = []
        for a in alarms where a.isOn {
            var next: [Date] = []
            for d in (a.weekdays.isEmpty ? [nil] : a.weekdays.sorted().map { Optional($0) }) {
                var dc = DateComponents(hour: a.hour, minute: a.minute)
                dc.weekday = d
                base.append(UNNotificationRequest(identifier: "\(a.id)-b\(d ?? 0)", content: content(a),
                            trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: d != nil)))
                if let n = cal.nextDate(after: Date(), matching: dc, matchingPolicy: .nextTime) { next.append(n) }
            }
            for (k, n) in next.sorted().prefix(3).enumerated() {
                for s in 1...3 {
                    let t = n.addingTimeInterval(Double(s) * 30)
                    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
                    extra.append((t, UNNotificationRequest(identifier: "\(a.id)-x\(k)-\(s)", content: content(a),
                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))))
                }
            }
        }
        let room = max(0, 60 - base.count)
        let chosen = Array((base + extra.sorted { $0.0 < $1.0 }.prefix(room).map(\.1)).prefix(62))
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { reqs in
            c.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { !$0.hasPrefix("snooze") })
            for r in chosen { c.add(r) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "다시 알림")
        let stop = UNNotificationAction(identifier: "STOP", title: "중단", options: [.destructive])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "ALARM_SNOOZE", actions: [snooze, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ALARM", actions: [stop], intentIdentifiers: [])
        ])
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        return true
    }

    // 앱이 켜져 있을 때 알람 → 전화 스타일 화면
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions {
        if let id = n.request.content.userInfo["id"] as? String { await AlarmStore.shared.present(id: id) }
        return []
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let id = r.notification.request.content.userInfo["id"] as? String else { return }
        let store = AlarmStore.shared
        switch r.actionIdentifier {
        case "SNOOZE":
            if let a = await store.item(id: id) { await store.snooze(a, fromRinging: false) }
        case "STOP":
            if let a = await store.item(id: id) { await store.cancelChain(a.id); await store.reschedule() }
        default:
            await store.present(id: id)
        }
    }
}

@main
struct AlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AlarmStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            AlarmListView()
                .environmentObject(store)
                .tint(.orange)
                .onChange(of: phase) { _, p in
                    if p == .active {
                        store.expireOneShots(); store.reschedule()
                        if store.ringing == nil { Ringer.shared.stop() }
                    } else if store.ringing == nil, store.alarms.contains(where: \.isOn) {
                        Ringer.shared.keepAlive()
                    }
                }
        }
    }
}

// MARK: - 목록

struct AlarmListView: View {
    @EnvironmentObject var store: AlarmStore
    @State private var editing: AlarmItem?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.sorted) { a in
                        AlarmRow(alarm: a)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = a }
                    }
                    .onDelete { idx in
                        let ids = idx.map { store.sorted[$0].id }
                        store.alarms.removeAll { ids.contains($0.id) }
                    }
                } header: {
                    Text("기타").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }
            .navigationTitle("알람")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { AlarmEditView(alarm: $0, isNew: false) }
            .sheet(isPresented: $adding) { AlarmEditView(alarm: AlarmItem(), isNew: true) }
            .fullScreenCover(item: $store.ringing) { RingingView(alarm: $0) }
        }
    }
}

struct AlarmRow: View {
    @EnvironmentObject var store: AlarmStore
    let alarm: AlarmItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(alarm.hour < 12 ? "오전" : "오후").font(.title)
                    Text(String(format: "%d:%02d", alarm.hour % 12 == 0 ? 12 : alarm.hour % 12, alarm.minute))
                        .font(.system(size: 52, weight: .light))
                }
                Text((alarm.label.isEmpty ? "알람" : alarm.label)
                     + (alarm.weekdays.isEmpty ? "" : ", \(alarm.repeatText)"))
                    .font(.subheadline)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { alarm.isOn },
                set: { v in var x = alarm; x.isOn = v; x.arm(); store.upsert(x) }
            )).labelsHidden()
        }
        .foregroundStyle(alarm.isOn ? .primary : .secondary)
        .padding(.vertical, 4)
    }
}

// MARK: - 추가 / 편집

struct AlarmEditView: View {
    @EnvironmentObject var store: AlarmStore
    @Environment(\.dismiss) private var dismiss
    @State var alarm: AlarmItem
    @State private var time: Date
    let isNew: Bool

    init(alarm: AlarmItem, isNew: Bool) {
        _alarm = State(initialValue: alarm)
        _time = State(initialValue: Calendar.current.date(
            from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? Date())
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                }
                Section {
                    NavigationLink {
                        RepeatView(days: $alarm.weekdays)
                    } label: {
                        HStack { Text("반복"); Spacer(); Text(alarm.repeatText).foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text("레이블")
                        TextField("알람", text: $alarm.label).multilineTextAlignment(.trailing)
                    }
                    Toggle("다시 알림", isOn: $alarm.snooze)
                }
                if !isNew {
                    Section {
                        Button("알람 삭제", role: .destructive) {
                            store.alarms.removeAll { $0.id == alarm.id }
                            dismiss()
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "알람 추가" : "알람 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        alarm.hour = c.hour ?? 0
                        alarm.minute = c.minute ?? 0
                        alarm.isOn = true
                        alarm.arm()
                        store.upsert(alarm)
                        dismiss()
                    }.bold()
                }
            }
        }
    }
}

struct RepeatView: View {
    @Binding var days: Set<Int>
    private let names = ["일", "월", "화", "수", "목", "금", "토"]

    var body: some View {
        List(1...7, id: \.self) { d in
            Button {
                if days.contains(d) { days.remove(d) } else { days.insert(d) }
            } label: {
                HStack {
                    Text("\(names[d - 1])요일마다").foregroundStyle(.primary)
                    Spacer()
                    if days.contains(d) { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle("반복")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 알람 울림 화면 (전화 수신 화면 스타일)

struct RingingView: View {
    @EnvironmentObject var store: AlarmStore
    let alarm: AlarmItem
    @State private var dx: CGFloat = 0
    private let knob: CGFloat = 72

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.63, green: 0.64, blue: 0.69),
                                    Color(red: 0.46, green: 0.47, blue: 0.52)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .ignoresSafeArea()
            VStack {
                Text(alarm.label.isEmpty ? "알람" : alarm.label)
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 120)
                    .padding(.horizontal, 24)
                Spacer()
                HStack {
                    if alarm.snooze {
                        Button { store.snooze(alarm) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "bell.fill").font(.title2)
                                    .frame(width: 66, height: 66)
                                    .background(.white.opacity(0.15), in: Circle())
                                Text("다시 알림").font(.callout)
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 34)
                slider
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var slider: some View {
        GeometryReader { g in
            let maxX = g.size.width - knob - 12
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.12))
                Text("밀어서 통화하기")
                    .font(.title2)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                    .opacity(max(0, 1 - Double(dx / maxX) * 1.4))
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Image(systemName: "phone.fill").font(.title).foregroundStyle(.green))
                    .padding(6)
                    .offset(x: dx)
                    .gesture(
                        DragGesture()
                            .onChanged { dx = min(max(0, $0.translation.width), maxX) }
                            .onEnded { _ in
                                if dx > maxX * 0.85 { store.endRinging() }
                                else { withAnimation(.spring) { dx = 0 } }
                            }
                    )
            }
        }
        .frame(height: 84)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}
