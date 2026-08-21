import Cocoa
import SwiftUI
import Combine
import UserNotifications
import CryptoKit

// ==========================================
// 1. Zero-Prompt Hardware-Encrypted Secure Storage
// ==========================================
class SecureStorage {
    private static let appSupportDir: URL = {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.dharana.focus-tracker", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        return dir
    }()
    
    private static var vaultFile: URL {
        return appSupportDir.appendingPathComponent(".token_vault.dat")
    }
    
    private static var masterKeyFile: URL {
        return appSupportDir.appendingPathComponent(".master_key.dat")
    }
    
    private static func getOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: masterKeyFile), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try? keyData.write(to: masterKeyFile, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: masterKeyFile.path)
        return newKey
    }
    
    static func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: vaultFile)
            return
        }
        
        guard let data = trimmed.data(using: .utf8) else { return }
        let symKey = getOrCreateKey()
        
        do {
            let sealedBox = try AES.GCM.seal(data, using: symKey)
            if let combined = sealedBox.combined {
                try combined.write(to: vaultFile, options: [.atomic, .completeFileProtection])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultFile.path)
            }
        } catch {
            print("SecureStorage encryption error:", error)
        }
    }
    
    static func load() -> String {
        guard FileManager.default.fileExists(atPath: vaultFile.path),
              let combinedData = try? Data(contentsOf: vaultFile) else {
            // Fallback migration from legacy unencrypted UserDefaults plist
            if let legacyKey = UserDefaults.standard.string(forKey: "dharana_gemini_api_key"), !legacyKey.isEmpty {
                save(key: legacyKey)
                UserDefaults.standard.removeObject(forKey: "dharana_gemini_api_key")
                return legacyKey
            }
            return ""
        }
        
        let symKey = getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: symKey)
            return String(data: decryptedData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// ==========================================
// 2. Break Activity Types
// ==========================================
enum BreakActivity: String, CaseIterable, Identifiable {
    case stretching = "Full Body Stretch 🧘‍♀️"
    case breathing = "4-4-6-2 Breathing 🌬️"
    case walking = "Walk & Stroll 🚶‍♀️"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .stretching: return "figure.flexibility"
        case .breathing: return "wind"
        case .walking: return "figure.walk"
        }
    }
}

// ==========================================
// 3. TaskState (ObservableObject)
// ==========================================
class TaskState: ObservableObject {
    @Published var currentTask: String = "Focus Session 🧘"
    @Published var previousFocusTask: String = "Focus Session 🧘"
    @Published var isVisible: Bool = true
    @Published var recentTasks: [String] {
        didSet {
            UserDefaults.standard.set(recentTasks, forKey: "dharana_recent_tasks")
        }
    }
    
    // Auto-hide & Overlay Behavior Settings
    @Published var autoHideWhileTyping: Bool {
        didSet { saveSettings() }
    }
    @Published var autoHideOnIdle: Bool {
        didSet { saveSettings() }
    }
    @Published var idleTimeout: Double {
        didSet { saveSettings() }
    }
    @Published var overlayOpacity: Double {
        didSet { saveSettings() }
    }
    
    // Encrypted API Key
    @Published var isGeneratingAI: Bool = false
    @Published var geminiApiKey: String = SecureStorage.load()
    
    // Timer State
    @Published var timerRemaining: Int = 0
    @Published var isTimerActive: Bool = false
    @Published var isTimerPaused: Bool = false
    private var countdownTimer: AnyCancellable?
    
    // Break Mode & Popup State
    @Published var isBreakMode: Bool = false
    @Published var showBreakPopup: Bool = false
    @Published var selectedBreakActivity: BreakActivity = .stretching
    @Published var breakTimerRemaining: Int = 300 // 5 minutes default
    @Published var isBreakTimerActive: Bool = false
    @Published var breakTotalDuration: Int = 300
    private var breakCountdownTimer: AnyCancellable?
    
    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "dharana_recent_tasks"), !saved.isEmpty {
            self.recentTasks = saved
        } else {
            self.recentTasks = [
                "Coding 💻",
                "Writing 📝",
                "Debugging 🐛",
                "Meetings 🤝",
                "Stretch & Breathe 🧘‍♀️"
            ]
        }
        
        // Load overlay preferences
        self.autoHideWhileTyping = UserDefaults.standard.object(forKey: "dharana_auto_hide_typing") == nil ? true : UserDefaults.standard.bool(forKey: "dharana_auto_hide_typing")
        self.autoHideOnIdle = UserDefaults.standard.object(forKey: "dharana_auto_hide_idle") == nil ? true : UserDefaults.standard.bool(forKey: "dharana_auto_hide_idle")
        let savedTimeout = UserDefaults.standard.double(forKey: "dharana_idle_timeout")
        self.idleTimeout = savedTimeout == 0 ? 3.0 : savedTimeout
        let savedOpacity = UserDefaults.standard.double(forKey: "dharana_overlay_opacity")
        self.overlayOpacity = savedOpacity == 0 ? 0.9 : savedOpacity
    }
    
    func saveSettings() {
        SecureStorage.save(key: geminiApiKey)
        UserDefaults.standard.set(autoHideWhileTyping, forKey: "dharana_auto_hide_typing")
        UserDefaults.standard.set(autoHideOnIdle, forKey: "dharana_auto_hide_idle")
        UserDefaults.standard.set(idleTimeout, forKey: "dharana_idle_timeout")
        UserDefaults.standard.set(overlayOpacity, forKey: "dharana_overlay_opacity")
    }
    
    // Focus Timer Actions
    func startTimer(durationInSeconds: Int) {
        stopBreak()
        stopTimer()
        previousFocusTask = currentTask
        timerRemaining = durationInSeconds
        isTimerActive = true
        isTimerPaused = false
        isBreakMode = false
        
        countdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.timerRemaining > 0 {
                    self.timerRemaining -= 1
                } else {
                    self.timerExpired()
                }
            }
    }
    
    func pauseTimer() {
        guard isTimerActive && !isTimerPaused else { return }
        isTimerPaused = true
        countdownTimer?.cancel()
        countdownTimer = nil
    }
    
    func resumeTimer() {
        guard isTimerActive && isTimerPaused && timerRemaining > 0 else { return }
        isTimerPaused = false
        
        countdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.timerRemaining > 0 {
                    self.timerRemaining -= 1
                } else {
                    self.timerExpired()
                }
            }
    }
    
    func toggleTimerPause() {
        if isTimerPaused {
            resumeTimer()
        } else if isTimerActive {
            pauseTimer()
        }
    }
    
    func stopTimer() {
        isTimerActive = false
        isTimerPaused = false
        timerRemaining = 0
        countdownTimer?.cancel()
        countdownTimer = nil
    }
    
    private func timerExpired() {
        stopTimer()
        NSSound.beep()
        triggerBreak(durationInSeconds: 300)
        sendBreakNotification()
    }
    
    // Break Actions
    func triggerBreak(durationInSeconds: Int = 300, activity: BreakActivity? = nil) {
        if !isBreakMode {
            previousFocusTask = currentTask
        }
        stopTimer()
        isBreakMode = true
        if let act = activity {
            selectedBreakActivity = act
        }
        currentTask = "Stretch & Breathe Break 🧘‍♀️🌬️"
        breakTotalDuration = durationInSeconds
        breakTimerRemaining = durationInSeconds
        isBreakTimerActive = true
        showBreakPopup = true
        
        breakCountdownTimer?.cancel()
        breakCountdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.breakTimerRemaining > 0 {
                    self.breakTimerRemaining -= 1
                } else {
                    self.breakExpired()
                }
            }
    }
    
    func pauseOrResumeBreakTimer() {
        if isBreakTimerActive {
            isBreakTimerActive = false
            breakCountdownTimer?.cancel()
            breakCountdownTimer = nil
        } else {
            isBreakTimerActive = true
            breakCountdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    if self.breakTimerRemaining > 0 {
                        self.breakTimerRemaining -= 1
                    } else {
                        self.breakExpired()
                    }
                }
        }
    }
    
    func setBreakDuration(_ seconds: Int) {
        breakTotalDuration = seconds
        breakTimerRemaining = seconds
    }
    
    func stopBreak() {
        isBreakMode = false
        isBreakTimerActive = false
        breakCountdownTimer?.cancel()
        breakCountdownTimer = nil
        showBreakPopup = false
    }
    
    func resumeFocus(newTask: String? = nil) {
        stopBreak()
        if let newTask = newTask, !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentTask = newTask
        } else {
            currentTask = previousFocusTask.isEmpty ? "Focus Session 🧘" : previousFocusTask
        }
    }
    
    private func breakExpired() {
        stopBreak()
        currentTask = previousFocusTask.isEmpty ? "Focus Session 🧘" : previousFocusTask
        NSSound.beep()
        
        let content = UNMutableNotificationContent()
        content.title = "Break Complete! 🚀"
        content.body = "You're refreshed and ready! Let's get back into the zone."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "DharanaBreakComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    private func sendBreakNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Focus Complete! Time to Stretch 🧘‍♀️🌬️"
        content.body = "Step away from your desk! Follow the stretching routines or 4-4-6-2 calming breathwork."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "DharanaTimerExpired", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error:", error)
            }
        }
    }
}

// ==========================================
// 4. Ephemeral Gemini AI Service
// ==========================================
class AIService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()
    
    static func suggestTask(apiKey: String, context: String, completion: @escaping (String?) -> Void) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            completion(nil)
            return
        }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key")
        
        let sanitizedContext = String(context.prefix(120).filter { $0.isLetter || $0.isNumber || $0.isWhitespace || "-_./:".contains($0) })
        let prompt = "Suggest a single, active task description (max 4 words, 1 emoji at end) for: '\(sanitizedContext)'. Output ONLY the task name."
        
        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.6,
                "maxOutputTokens": 60
            ]
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(nil)
            return
        }
        request.httpBody = httpBody
        
        session.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(cleaned)
            } else {
                completion(nil)
            }
        }.resume()
    }
}

// ==========================================
// 5. Rich Animated Break Views
// ==========================================

// A. Walking Animation View (Walking stickman, dynamic road, floating wind, step counter)
struct WalkAnimationView: View {
    @State private var walkPhase: Bool = false
    @State private var roadOffset: CGFloat = 0
    @State private var stepCount: Int = 12
    @State private var breezeOffset: CGFloat = 0
    
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    let continuousTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background sky & ambient motion glow
                LinearGradient(
                    gradient: Gradient(colors: [Color.cyan.opacity(0.18), Color.blue.opacity(0.08), Color.black.opacity(0.4)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(12)
                
                // Breeze / wind lines drifting by
                VStack(spacing: 24) {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.cyan.opacity(0.25))
                            .frame(width: CGFloat(40 + (i * 25)), height: 2)
                            .offset(x: breezeOffset + CGFloat(i * 30), y: CGFloat(i * 20 - 30))
                    }
                }
                
                // Ground / Moving treadmill road with animated dashes
                VStack {
                    Spacer()
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 2)
                        
                        // Dashed path moving to the left
                        HStack(spacing: 16) {
                            ForEach(0..<15) { _ in
                                Rectangle()
                                    .fill(Color.cyan.opacity(0.7))
                                    .frame(width: 14, height: 3)
                            }
                        }
                        .offset(x: roadOffset)
                        .clipped()
                    }
                    .frame(height: 10)
                    .padding(.bottom, 24)
                }
                
                // Animated Walking Character Rig
                VStack(spacing: 0) {
                    // Head with bounce and headphones/cap glow
                    ZStack {
                        Circle()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.yellow, Color.orange]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 22, height: 22)
                            .shadow(color: Color.orange.opacity(0.6), radius: 4)
                        
                        // Eyes
                        HStack(spacing: 4) {
                            Circle().fill(Color.black).frame(width: 2.5, height: 2.5)
                            Circle().fill(Color.black).frame(width: 2.5, height: 2.5)
                        }
                        .offset(x: 2, y: -1)
                    }
                    .offset(y: walkPhase ? -3 : 2)
                    
                    // Torso & Swinging Arms
                    ZStack {
                        // Body
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.cyan, Color.blue]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 16, height: 32)
                        
                        // Back Arm
                        Capsule()
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: 6, height: 22)
                            .rotationEffect(Angle(degrees: walkPhase ? -35 : 35), anchor: .top)
                            .offset(x: -6, y: -4)
                        
                        // Front Arm
                        Capsule()
                            .fill(Color.cyan)
                            .frame(width: 6, height: 22)
                            .rotationEffect(Angle(degrees: walkPhase ? 35 : -35), anchor: .top)
                            .offset(x: 6, y: -4)
                    }
                    .offset(y: walkPhase ? -1 : 1)
                    
                    // Legs swinging in opposition
                    HStack(spacing: 4) {
                        // Left Leg
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.9), Color.cyan]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 6, height: 26)
                            .rotationEffect(Angle(degrees: walkPhase ? 32 : -32), anchor: .top)
                        
                        // Right Leg
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.9), Color.cyan]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 6, height: 26)
                            .rotationEffect(Angle(degrees: walkPhase ? -32 : 32), anchor: .top)
                    }
                    .offset(y: -4)
                }
                .offset(y: -6)
                
                // Top Overlay Prompt & Step Counter
                VStack {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "figure.walk.motion")
                                .foregroundColor(.cyan)
                            Text("\(stepCount) Steps")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(6)
                        
                        Spacer()
                        
                        Text("Goal: ~250 steps 🚶")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.cyan)
                    }
                    .padding(10)
                    
                    Spacer()
                }
            }
            .frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
            )
            .onReceive(timer) { _ in
                withAnimation(.easeInOut(duration: 0.35)) {
                    walkPhase.toggle()
                    stepCount += 2
                }
            }
            .onReceive(continuousTimer) { _ in
                roadOffset -= 3
                if roadOffset <= -30 { roadOffset = 0 }
                
                breezeOffset -= 2
                if breezeOffset <= -120 { breezeOffset = 120 }
            }
            
            // Movement prompt cards
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "shoeprints.fill")
                        .foregroundColor(.cyan)
                        .font(.system(size: 12))
                    Text("Stand up & walk across the room or hallway")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cyan.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

// B. Girl Full Body Stretching Animation View (Animated girl stretching hands, side body, hamstrings, quads)
struct StretchPose {
    let name: String
    let title: String
    let subtitle: String
    let tip: String
    let leftArmRotation: Double
    let rightArmRotation: Double
    let leftArmOffsetX: CGFloat
    let leftArmOffsetY: CGFloat
    let rightArmOffsetX: CGFloat
    let rightArmOffsetY: CGFloat
    let torsoAngle: Double
    let torsoOffsetY: CGFloat
    let headOffsetY: CGFloat
    let leftLegAngle: Double
    let rightLegAngle: Double
    let rightLegScaleY: CGFloat
}

struct GirlStretchingAnimationView: View {
    @State private var poseIndex: Int = 0
    @State private var hairSway: Bool = false
    @State private var breathPulse: Bool = false
    
    let poseTimer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()
    let microTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    
    let poses: [StretchPose] = [
        // 1. Overhead Hands & Sky Reach (Hands / Wrists / Spine)
        StretchPose(
            name: "Overhead Reach",
            title: "🙆‍♀️ Overhead Hand & Spine Stretch",
            subtitle: "Elongate spine, clasp hands, reach to ceiling",
            tip: "Interlace fingers, push palms up, stretch wrists & shoulders",
            leftArmRotation: -160,
            rightArmRotation: 160,
            leftArmOffsetX: -6,
            leftArmOffsetY: -18,
            rightArmOffsetX: 6,
            rightArmOffsetY: -18,
            torsoAngle: 0,
            torsoOffsetY: -4,
            headOffsetY: -5,
            leftLegAngle: 0,
            rightLegAngle: 0,
            rightLegScaleY: 1.0
        ),
        // 2. Side Body & Ribs Lat Stretch (Waist & Obliques)
        StretchPose(
            name: "Side Body Stretch",
            title: "🧘‍♀️ Side Torso & Rib Stretch",
            subtitle: "Open side body, stretch obliques & latissimus",
            tip: "Reach arm overhead to the side, open ribs and breathe deep",
            leftArmRotation: -20,
            rightArmRotation: 130,
            leftArmOffsetX: -14,
            leftArmOffsetY: 2,
            rightArmOffsetX: 8,
            rightArmOffsetY: -14,
            torsoAngle: 18,
            torsoOffsetY: 0,
            headOffsetY: -1,
            leftLegAngle: -10,
            rightLegAngle: 10,
            rightLegScaleY: 1.0
        ),
        // 3. Forward Hamstring & Leg Stretch (Legs & Calves)
        StretchPose(
            name: "Hamstring Fold",
            title: "🤸‍♀️ Hamstring & Leg Fold",
            subtitle: "Reach hands towards toes, relax neck & calves",
            tip: "Hinge at hips, reach down to toes, release lower back tension",
            leftArmRotation: -55,
            rightArmRotation: -45,
            leftArmOffsetX: -6,
            leftArmOffsetY: 12,
            rightArmOffsetX: 6,
            rightArmOffsetY: 12,
            torsoAngle: -36,
            torsoOffsetY: 6,
            headOffsetY: 8,
            leftLegAngle: 0,
            rightLegAngle: 0,
            rightLegScaleY: 0.95
        ),
        // 4. Standing Quad & Shoulder Opener (Quads & Hips)
        StretchPose(
            name: "Quad & Chest",
            title: "🏃‍♀️ Quad & Chest Opener",
            subtitle: "Bend leg, pull shoulders back, open chest",
            tip: "Hold ankle behind you, pull shoulder back, stand tall and balance",
            leftArmRotation: -35,
            rightArmRotation: 75,
            leftArmOffsetX: -14,
            leftArmOffsetY: 0,
            rightArmOffsetX: 12,
            rightArmOffsetY: -4,
            torsoAngle: -4,
            torsoOffsetY: -2,
            headOffsetY: -2,
            leftLegAngle: 0,
            rightLegAngle: -50,
            rightLegScaleY: 0.75
        )
    ]
    
    var currentPose: StretchPose {
        poses[poseIndex % poses.count]
    }
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Calming gradient background
                LinearGradient(
                    gradient: Gradient(colors: [Color.purple.opacity(0.22), Color.pink.opacity(0.12), Color.black.opacity(0.4)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .cornerRadius(12)
                
                // Active stretch energy aura rings
                ForEach(0..<2) { i in
                    Circle()
                        .stroke(Color.pink.opacity(breathPulse ? 0.35 : 0.08), lineWidth: 1.5)
                        .frame(width: CGFloat(90 + (i * 45)), height: CGFloat(90 + (i * 45)))
                        .scaleEffect(breathPulse ? 1.06 : 0.94)
                }
                
                // Stylized Animated Girl Character Rig
                VStack(spacing: 0) {
                    // Head with Ponytail & Cute Face
                    ZStack {
                        // Ponytail swinging behind head
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.35, green: 0.2, blue: 0.1), Color(red: 0.55, green: 0.3, blue: 0.15)]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 8, height: 22)
                            .rotationEffect(Angle(degrees: hairSway ? -25 : -10), anchor: .topTrailing)
                            .offset(x: -12, y: -2)
                        
                        // Head / Face
                        Circle()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.78), Color(red: 0.98, green: 0.82, blue: 0.72)]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 22, height: 22)
                            .shadow(color: Color.pink.opacity(0.4), radius: 4)
                        
                        // Headband
                        Capsule()
                            .fill(Color.pink.opacity(0.85))
                            .frame(width: 20, height: 4)
                            .offset(y: -7)
                        
                        // Face Details (Eyes & Smile)
                        VStack(spacing: 1) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(red: 0.2, green: 0.15, blue: 0.15)).frame(width: 2.5, height: 2.5)
                                Circle().fill(Color(red: 0.2, green: 0.15, blue: 0.15)).frame(width: 2.5, height: 2.5)
                            }
                            Text("‿")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundColor(Color(red: 0.3, green: 0.2, blue: 0.2))
                        }
                        .offset(y: 1)
                    }
                    .offset(y: currentPose.headOffsetY)
                    
                    // Torso (Activewear Top) & Arms
                    ZStack {
                        // Top / Upper Body
                        Capsule()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.pink, Color.purple]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 18, height: 32)
                            .scaleEffect(x: breathPulse ? 1.05 : 0.95, y: 1.0)
                        
                        // Left Arm
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.84, blue: 0.74))
                            .frame(width: 5.5, height: 24)
                            .rotationEffect(Angle(degrees: currentPose.leftArmRotation), anchor: .top)
                            .offset(x: currentPose.leftArmOffsetX, y: currentPose.leftArmOffsetY)
                        
                        // Right Arm
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.84, blue: 0.74))
                            .frame(width: 5.5, height: 24)
                            .rotationEffect(Angle(degrees: currentPose.rightArmRotation), anchor: .top)
                            .offset(x: currentPose.rightArmOffsetX, y: currentPose.rightArmOffsetY)
                    }
                    .rotationEffect(Angle(degrees: currentPose.torsoAngle))
                    .offset(y: currentPose.torsoOffsetY)
                    
                    // Lower Body (Athletic Leggings & Legs)
                    HStack(spacing: 6) {
                        // Left Leg
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.15, green: 0.18, blue: 0.28), Color(red: 0.25, green: 0.28, blue: 0.42)]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 6, height: 26)
                            .rotationEffect(Angle(degrees: currentPose.leftLegAngle), anchor: .top)
                        
                        // Right Leg
                        Capsule()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.15, green: 0.18, blue: 0.28), Color(red: 0.25, green: 0.28, blue: 0.42)]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 6, height: 26)
                            .scaleEffect(y: currentPose.rightLegScaleY, anchor: .top)
                            .rotationEffect(Angle(degrees: currentPose.rightLegAngle), anchor: .top)
                    }
                    .offset(y: -3)
                }
                .offset(y: 4)
                
                // Top Tag: Current Pose Name & Progress
                VStack {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "figure.flexibility")
                                .foregroundColor(.pink)
                            Text(currentPose.name.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(6)
                        
                        Spacer()
                        
                        Text("Pose \(poseIndex + 1) of \(poses.count) ✨")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.pink)
                    }
                    .padding(10)
                    Spacer()
                }
            }
            .frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.pink.opacity(0.35), lineWidth: 1)
            )
            .onReceive(poseTimer) { _ in
                withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) {
                    poseIndex = (poseIndex + 1) % poses.count
                }
            }
            .onReceive(microTimer) { _ in
                withAnimation(.easeInOut(duration: 0.8)) {
                    hairSway.toggle()
                    breathPulse.toggle()
                }
            }
            
            // Dynamic stretch instructions card & quick pose switcher
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.pink)
                        .font(.system(size: 11))
                    Text(currentPose.tip)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pink.opacity(0.12))
                .cornerRadius(8)
                
                // Quick Pose Switcher Pills
                HStack(spacing: 6) {
                    ForEach(0..<poses.count, id: \.self) { i in
                        Button(action: {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                                poseIndex = i
                            }
                        }) {
                            Text(poses[i].name)
                                .font(.system(size: 9, weight: poseIndex == i ? .bold : .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity)
                                .background(poseIndex == i ? Color.pink.opacity(0.3) : Color.white.opacity(0.04))
                                .foregroundColor(poseIndex == i ? .white : .gray)
                                .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }
}

// C. 4-4-6-2 Pranayama / Box Breathing View (4s Inhale, 4s Hold, 6s Exhale, 2s Hold for 5 Rounds)
enum PranayamaPhase: String {
    case inhale = "Inhale"
    case holdIn = "Hold"
    case exhale = "Exhale"
    case holdOut = "Pause"
    
    var duration: Int {
        switch self {
        case .inhale: return 4
        case .holdIn: return 4
        case .exhale: return 6
        case .holdOut: return 2
        }
    }
    
    var instruction: String {
        switch self {
        case .inhale: return "🌬️ Inhale deeply through nose, expand lungs"
        case .holdIn: return "✨ Hold breath gently, relax face & shoulders"
        case .exhale: return "😮‍💨 Exhale slowly through mouth, release tension"
        case .holdOut: return "🌿 Pause empty, soften body and reset"
        }
    }
    
    var color: Color {
        switch self {
        case .inhale: return Color.cyan
        case .holdIn: return Color.purple
        case .exhale: return Color.emeraldGreen
        case .holdOut: return Color.orange
        }
    }
}

struct BoxBreathingAnimationView: View {
    @State private var phase: PranayamaPhase = .inhale
    @State private var secondsRemaining: Int = 4
    @State private var currentRound: Int = 1
    @State private var isRunning: Bool = true
    @State private var isCompleted: Bool = false
    @State private var ringScale: CGFloat = 0.65
    
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Calming ambient background
                LinearGradient(
                    gradient: Gradient(colors: [phase.color.opacity(0.22), Color.indigo.opacity(0.12), Color.black.opacity(0.4)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(12)
                
                // Expanding / Contracting Breathing Ripple Rings
                ZStack {
                    Circle()
                        .stroke(phase.color.opacity(0.35), lineWidth: 2)
                        .scaleEffect(ringScale * 1.15)
                    
                    Circle()
                        .fill(phase.color.opacity(0.18))
                        .scaleEffect(ringScale)
                        .blur(radius: 6)
                    
                    // Inner Stage Content
                    VStack(spacing: 2) {
                        if isCompleted {
                            Text("🎉")
                                .font(.system(size: 24))
                            Text("5 Rounds Complete!")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Mind calm & refreshed ✨")
                                .font(.system(size: 10))
                                .foregroundColor(.emeraldGreen)
                        } else {
                            Text(phase.rawValue.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(phase.color)
                            
                            Text("\(secondsRemaining)")
                                .font(.system(size: 32, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: phase.color.opacity(0.6), radius: 6)
                            
                            Text("(\(phase.duration)s)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(width: 140, height: 140)
                
                // Top Tag: 5 Round Tracker Indicators
                VStack {
                    HStack(spacing: 4) {
                        Text("4-4-6-2 PRANAYAMA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.gray)
                        
                        Spacer()
                        
                        // 5 Rounds progress indicators
                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { r in
                                HStack(spacing: 2) {
                                    if r < currentRound || isCompleted {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.emeraldGreen)
                                            .font(.system(size: 9))
                                    } else if r == currentRound {
                                        Circle()
                                            .fill(phase.color)
                                            .frame(width: 7, height: 7)
                                    } else {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                                            .frame(width: 7, height: 7)
                                    }
                                    Text("Rd \(r)")
                                        .font(.system(size: 8, weight: r == currentRound ? .bold : .regular))
                                        .foregroundColor(r <= currentRound ? .white : .gray)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(r == currentRound && !isCompleted ? phase.color.opacity(0.18) : Color.black.opacity(0.3))
                                .cornerRadius(4)
                            }
                        }
                    }
                    .padding(10)
                    Spacer()
                }
            }
            .frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(phase.color.opacity(0.35), lineWidth: 1)
            )
            .onReceive(timer) { _ in
                handleTick()
            }
            .onAppear {
                startInhaleAnimation()
            }
            
            // Phase instructions & restart button
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isCompleted ? "checkmark.seal.fill" : "wind")
                        .foregroundColor(phase.color)
                        .font(.system(size: 11))
                    Text(isCompleted ? "5 rounds completed. Your nervous system is grounded." : phase.instruction)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(phase.color.opacity(0.12))
                .cornerRadius(8)
                
                Button(action: restartBreathing) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                        Text(isCompleted ? "Restart" : "Reset")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(phase.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(phase.color.opacity(0.15))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func handleTick() {
        guard isRunning && !isCompleted else { return }
        
        if secondsRemaining > 1 {
            secondsRemaining -= 1
        } else {
            // Transition to next phase
            switch phase {
            case .inhale:
                phase = .holdIn
                secondsRemaining = 4
            case .holdIn:
                phase = .exhale
                secondsRemaining = 6
                startExhaleAnimation()
            case .exhale:
                phase = .holdOut
                secondsRemaining = 2
            case .holdOut:
                if currentRound < 5 {
                    currentRound += 1
                    phase = .inhale
                    secondsRemaining = 4
                    startInhaleAnimation()
                } else {
                    isCompleted = true
                    isRunning = false
                }
            }
        }
    }
    
    private func startInhaleAnimation() {
        withAnimation(.easeInOut(duration: 4.0)) {
            ringScale = 1.25
        }
    }
    
    private func startExhaleAnimation() {
        withAnimation(.easeInOut(duration: 6.0)) {
            ringScale = 0.65
        }
    }
    
    private func restartBreathing() {
        currentRound = 1
        phase = .inhale
        secondsRemaining = 4
        isCompleted = false
        isRunning = true
        startInhaleAnimation()
    }
}

extension Color {
    static let emeraldGreen = Color(red: 16/255, green: 185/255, blue: 129/255)
}

// ==========================================
// 6. Break Pop-Up Modal Window View
// ==========================================
struct BreakPopupView: View {
    @ObservedObject var state: TaskState
    @State private var customTaskToResume: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            // Header: Title & Close
            HStack {
                HStack(spacing: 8) {
                    Text("🎉")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Time to Move & Recharge!")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("Step away from your desk — stretch your body & breathe deep!")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    state.showBreakPopup = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Minimize break popup")
            }
            
            // Tab Selector for Break Activities
            HStack(spacing: 8) {
                ForEach(BreakActivity.allCases) { activity in
                    Button(action: {
                        withAnimation(.spring()) {
                            state.selectedBreakActivity = activity
                        }
                    }) {
                        HStack(spacing: 5) {
                            Text(activity.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(state.selectedBreakActivity == activity ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                        .foregroundColor(state.selectedBreakActivity == activity ? .white : .gray)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(state.selectedBreakActivity == activity ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            // Active Animation View
            Group {
                switch state.selectedBreakActivity {
                case .stretching:
                    GirlStretchingAnimationView()
                case .breathing:
                    BoxBreathingAnimationView()
                case .walking:
                    WalkAnimationView()
                }
            }
            
            // Break Timer Card & Controls
            HStack(spacing: 12) {
                // Digital Countdown & Progress
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .foregroundColor(.green)
                    Text(formatTime(state.breakTimerRemaining))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                
                // Play / Pause Button
                Button(action: {
                    state.pauseOrResumeBreakTimer()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: state.isBreakTimerActive ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                        Text(state.isBreakTimerActive ? "Pause" : "Resume")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Quick Duration Presets
                ForEach([3, 5, 10], id: \.self) { mins in
                    Button("\(mins)m") {
                        state.setBreakDuration(mins * 60)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(state.breakTotalDuration == (mins * 60) ? Color.cyan.opacity(0.25) : Color.white.opacity(0.05))
                    .foregroundColor(state.breakTotalDuration == (mins * 60) ? .cyan : .gray)
                    .cornerRadius(6)
                }
                
                Spacer()
            }
            
            Divider().background(Color.white.opacity(0.1))
            
            // Footer: Resume Focus Button
            HStack(spacing: 10) {
                Button(action: {
                    state.resumeFocus(newTask: customTaskToResume)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12))
                        Text("I'm Refreshed! Resume Focus 🧘")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.indigo, Color.purple]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                    .shadow(color: Color.indigo.opacity(0.4), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button("Keep Floating 🪟") {
                    state.showBreakPopup = false
                }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(VisualEffectView().edgesIgnoringSafeArea(.all))
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// ==========================================
// 7. Overlay view that follows the cursor
// ==========================================
struct CursorOverlayView: View {
    @ObservedObject var state: TaskState
    @State private var iconToggle: Bool = false
    
    let iconTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 8) {
            if state.isBreakMode {
                // Dynamic Break Indicator (Stretching / Breathing / Walking)
                Text(state.selectedBreakActivity == .stretching
                     ? (iconToggle ? "🧘‍♀️" : "🙆‍♀️")
                     : (state.selectedBreakActivity == .breathing
                        ? (iconToggle ? "🌬️" : "🫁")
                        : (iconToggle ? "🚶‍♀️" : "🏃‍♀️")))
                    .font(.system(size: 12))
                    .shadow(color: Color.cyan.opacity(0.8), radius: 4)
            } else {
                Circle()
                    .fill(state.isTimerActive ? (state.isTimerPaused ? Color.yellow : Color.green) : Color.indigo)
                    .frame(width: 6, height: 6)
            }
            
            Text(state.currentTask)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundColor(.white)
                .lineLimit(1)
            
            if state.isBreakMode {
                // Break Countdown
                Text(formatTime(state.breakTimerRemaining))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.cyan.opacity(0.2))
                    .cornerRadius(3)
            } else if state.isTimerActive {
                Text(state.isTimerPaused ? "⏸ \(formatTime(state.timerRemaining))" : formatTime(state.timerRemaining))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(state.isTimerPaused ? .yellow : .green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background((state.isTimerPaused ? Color.yellow : Color.white).opacity(0.12))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(
                    Capsule()
                        .stroke(
                            state.isBreakMode
                                ? LinearGradient(gradient: Gradient(colors: [Color.cyan, Color.pink]), startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.1)]), startPoint: .top, endPoint: .bottom),
                            lineWidth: state.isBreakMode ? 1.5 : 1
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onReceive(iconTimer) { _ in
            if state.isBreakMode {
                iconToggle.toggle()
            }
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// ==========================================
// 8. Popover SwiftUI view for Tasks & Timers
// ==========================================
struct TaskPopoverView: View {
    @ObservedObject var state: TaskState
    @State private var showAISettings: Bool = false
    @State private var customMinutes: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let nsImg = (Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }) ?? NSImage(contentsOfFile: "/Users/jnaguboina/Dharana/Dharana.icns") {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .cornerRadius(5)
                }
                
                Text("Dharana - Focus")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        showAISettings.toggle()
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(state.geminiApiKey.isEmpty ? .gray : .indigo)
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())
                .help("API & Overlay Settings")
            }
            
            // Collapsible Settings
            if showAISettings {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GEMINI AI CONFIG")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)
                    
                    SecureField("Gemini API Key...", text: $state.geminiApiKey, onCommit: {
                        state.saveSettings()
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(6)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
                    .foregroundColor(.white)
                    .font(.system(size: 11))
                    
                    HStack {
                        Button("Save Key") {
                            state.saveSettings()
                            withAnimation { showAISettings = false }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.indigo)
                        
                        Spacer()
                        
                        Link("Get Gemini API Key 🔑", destination: URL(string: "https://aistudio.google.com/")!)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    Text("OVERLAY & TYPING BEHAVIOR")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)
                    
                    Toggle("Auto-hide while typing ⌨️", isOn: $state.autoHideWhileTyping)
                        .toggleStyle(SwitchToggleStyle(tint: .indigo))
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    
                    Toggle("Auto-hide when cursor idle ⏳", isOn: $state.autoHideOnIdle)
                        .toggleStyle(SwitchToggleStyle(tint: .indigo))
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    
                    if state.autoHideOnIdle {
                        HStack {
                            Text("Idle delay:")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(Int(state.idleTimeout))s")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                            Stepper("", value: $state.idleTimeout, in: 1...10, step: 1)
                                .labelsHidden()
                        }
                    }
                    
                    HStack {
                        Text("Opacity: \(Int(state.overlayOpacity * 100))%")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                        Spacer()
                        Slider(value: $state.overlayOpacity, in: 0.3...1.0, step: 0.05)
                            .frame(width: 110)
                    }
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Link(destination: URL(string: "https://buymeacoffee.com/9o0rFmKygY")!) {
                                HStack(spacing: 5) {
                                    Text("☕️")
                                    Text("Buy Me a Coffee")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.yellow)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.yellow.opacity(0.12))
                                .cornerRadius(6)
                            }
                            
                            Spacer()
                            
                            Text("v1.1")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                        
                        HStack(spacing: 4) {
                            Text("By")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                            Link("Bhayapaha Intelligence (www.bhayapaha.in)", destination: URL(string: "https://www.bhayapaha.in")!)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.indigo)
                        }
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Active task card
            VStack(alignment: .leading, spacing: 4) {
                Text("WHAT ARE YOU FOCUSING ON?")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 8) {
                    TextField("Enter custom focus...", text: $state.currentTask, onCommit: {
                        updateRecentTasks(with: state.currentTask)
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
                    
                    // AI Sparkles Generate Button
                    Button(action: triggerAISuggestion) {
                        if state.isGeneratingAI {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundColor(.indigo)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(state.isGeneratingAI)
                    .help("Auto-suggest task using Gemini AI")
                }
            }
            .padding(10)
            .background(Color.indigo.opacity(0.12))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.indigo.opacity(0.25), lineWidth: 1)
            )
            
            // Focus Timer Controls
            VStack(alignment: .leading, spacing: 7) {
                Text("FOCUS TIMER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                
                // Row 1: Digital Display + Presets + Pause + Stop
                HStack(spacing: 6) {
                    Text(formatTime(state.timerRemaining))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(state.isTimerActive ? (state.isTimerPaused ? .yellow : .green) : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background((state.isTimerActive && state.isTimerPaused ? Color.yellow.opacity(0.12) : Color.white.opacity(0.08)))
                        .cornerRadius(6)
                    
                    if !state.isTimerActive {
                        ForEach([15, 25, 50], id: \.self) { mins in
                            Button("\(mins)m") {
                                state.startTimer(durationInSeconds: mins * 60)
                                updateRecentTasks(with: state.currentTask)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                        }
                    } else {
                        // Pause / Resume Button
                        Button(action: {
                            state.toggleTimerPause()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: state.isTimerPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 8))
                                Text(state.isTimerPaused ? "Resume" : "Pause")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(state.isTimerPaused ? .green : .yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background((state.isTimerPaused ? Color.green : Color.yellow).opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // Stop Button
                        Button(action: {
                            state.stopTimer()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 8))
                                Text("Stop")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                
                // Row 2: Custom Minutes
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        TextField("mins", text: $customMinutes, onCommit: startCustomTimer)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(5)
                        
                        Text("min")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    
                    Button(action: startCustomTimer) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text("Set Custom Time")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.indigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.indigo.opacity(0.15))
                        .cornerRadius(5)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Spacer()
                }
            }
            
            // Dedicated Take a Break Action Card
            VStack(alignment: .leading, spacing: 6) {
                Text("BREAK & MOVEMENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                
                Button(action: {
                    state.triggerBreak(durationInSeconds: 300)
                }) {
                    HStack(spacing: 8) {
                        Text("🧘‍♀️🌬️")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Take a Stretch & Breath Break")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Text("5m girl stretch, 4-4-6-2 breath & walk")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan.opacity(0.9))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    .padding(8)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.cyan.opacity(0.2), Color.purple.opacity(0.2)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            // Quick switch favorites (top 3)
            if !state.recentTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("QUICK SWITCH")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 6) {
                        ForEach(Array(state.recentTasks.prefix(3)), id: \.self) { task in
                            Button(action: {
                                state.currentTask = task
                            }) {
                                Text(task)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(state.currentTask == task ? .white : .indigo)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(state.currentTask == task ? Color.indigo : Color.indigo.opacity(0.12))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            
            // Recent / Popular tasks list
            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK SELECT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(state.recentTasks, id: \.self) { task in
                            Button(action: {
                                state.currentTask = task
                            }) {
                                HStack {
                                    Text(task)
                                        .foregroundColor(state.currentTask == task ? .indigo : .white)
                                    Spacer()
                                    if state.currentTask == task {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.indigo)
                                    }
                                }
                                .padding(8)
                                .background(state.currentTask == task ? Color.indigo.opacity(0.1) : Color.white.opacity(0.04))
                                .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .frame(height: 100)
            }
            
            Divider().background(Color.white.opacity(0.1))
            
            // Toggles and Quit
            HStack {
                Toggle("Show Overlay", isOn: $state.isVisible)
                    .toggleStyle(SwitchToggleStyle(tint: .indigo))
                    .foregroundColor(.gray)
                    .font(.subheadline)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)
                .font(.subheadline)
            }
        }
        .padding(16)
        .frame(width: 300)
        .frame(minHeight: showAISettings ? 660 : 510)
        .background(VisualEffectView().edgesIgnoringSafeArea(.all))
    }
    
    private func startCustomTimer() {
        let cleaned = customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mins = Int(cleaned), mins > 0 {
            let clampedMins = min(mins, 720)
            state.startTimer(durationInSeconds: clampedMins * 60)
            updateRecentTasks(with: state.currentTask)
            customMinutes = ""
        }
    }
    
    private func updateRecentTasks(with task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !state.recentTasks.contains(trimmed) {
            state.recentTasks.insert(trimmed, at: 0)
            if state.recentTasks.count > 5 {
                state.recentTasks.removeLast()
            }
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private func triggerAISuggestion() {
        if state.geminiApiKey.isEmpty {
            state.isGeneratingAI = true
            let mockTasks = [
                "Refactoring Code 🛠️",
                "Fixing bugs 🐛",
                "Writing technical docs 📝",
                "Reviewing pull requests 🔍",
                "Designing database schemas 💾",
                "Setting up CI workflows ⚙️"
            ]
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                state.isGeneratingAI = false
                let suggested = mockTasks.randomElement() ?? "Writing code 💻"
                state.currentTask = suggested
                updateRecentTasks(with: suggested)
                
                let alert = NSAlert()
                alert.messageText = "Mock Gemini Suggestion"
                alert.informativeText = "To trigger real Gemini suggestions, configure your Gemini API Key inside the Settings panel (gear icon)."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        state.isGeneratingAI = true
        let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Xcode"
        let context = "User is currently focusing on: \(activeAppName)"
        
        AIService.suggestTask(apiKey: state.geminiApiKey, context: context) { suggested in
            DispatchQueue.main.async {
                state.isGeneratingAI = false
                if let suggested = suggested, !suggested.isEmpty {
                    state.currentTask = suggested
                    self.updateRecentTasks(with: suggested)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Gemini Request Failed"
                    alert.informativeText = "Could not invoke Gemini API. Please check your internet connection and verify that your Gemini API Key is valid."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

// ==========================================
// 9. NSVisualEffectView Blur Helper
// ==========================================
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ==========================================
// 10. App Delegate
// ==========================================
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var overlayWindow: NSWindow?
    var breakWindow: NSWindow?
    let taskState = TaskState()
    var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // Keyboard, Mouse Activity & Low-Power Idle Tracking
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?
    var globalMouseMonitor: Any?
    var lastTypingTimestamp: TimeInterval = 0
    var lastMouseMoveTimestamp: TimeInterval = CACurrentMediaTime()
    var lastMousePosition: NSPoint = .zero
    var currentOverlayAlpha: CGFloat = 0.0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "Dharana", withExtension: "icns"),
           let img = NSImage(contentsOf: iconUrl) {
            NSApp.applicationIconImage = img
        } else if let fallbackImg = NSImage(contentsOfFile: "/Users/jnaguboina/Dharana/Dharana.icns") {
            NSApp.applicationIconImage = fallbackImg
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        setupStatusItem()
        setupSettingsWindow()
        setupBreakWindow()
        setupOverlayWindow()
        setupEventMonitors()
        setupBreakStateObservers()
        startCursorTracking()
    }
    
    func setupBreakStateObservers() {
        taskState.$showBreakPopup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                if show {
                    self.showBreakPopup()
                } else {
                    self.breakWindow?.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }
    
    func setupEventMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            self?.lastTypingTimestamp = CACurrentMediaTime()
        }
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.lastTypingTimestamp = CACurrentMediaTime()
            return event
        }
        
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.lastMouseMoveTimestamp = CACurrentMediaTime()
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = " DHARANA "
            if let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Dharana") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeft
            }
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    func setupSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dharana - Focus"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TaskPopoverView(state: taskState))
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    
    func setupBreakWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dharana - Movement Break"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BreakPopupView(state: taskState))
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        
        self.breakWindow = window
    }
    
    func showBreakPopup() {
        if breakWindow == nil {
            setupBreakWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        breakWindow?.center()
        breakWindow?.makeKeyAndOrderFront(nil)
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
    
    func showRightClickMenu() {
        let menu = NSMenu()
        
        let headerItem = NSMenuItem(title: "Quick Switch Focus:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        
        let topTasks = Array(taskState.recentTasks.prefix(3))
        for (index, task) in topTasks.enumerated() {
            let item = NSMenuItem(title: task, action: #selector(quickSelectTask(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = task
            if taskState.currentTask == task {
                item.state = .on
            }
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        if taskState.isTimerActive {
            let pauseTitle = taskState.isTimerPaused ? "Resume Focus Timer ▶️" : "Pause Focus Timer ⏸"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePauseTimerAction), keyEquivalent: "p")
            pauseItem.target = self
            menu.addItem(pauseItem)
            
            let stopItem = NSMenuItem(title: "Stop Focus Timer ⏹", action: #selector(stopTimerAction), keyEquivalent: "s")
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        let breakItem = NSMenuItem(title: "Take Stretch Break 🧘‍♀️🌬️", action: #selector(triggerBreakMenuAction), keyEquivalent: "b")
        breakItem.target = self
        menu.addItem(breakItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Visit Bhayapaha Intelligence 🌐", action: #selector(openCompanyWebsite), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit App", action: #selector(quitApp), keyEquivalent: "q"))
        
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }
    
    @objc func togglePauseTimerAction() {
        taskState.toggleTimerPause()
    }
    
    @objc func stopTimerAction() {
        taskState.stopTimer()
    }
    
    @objc func triggerBreakMenuAction() {
        taskState.triggerBreak(durationInSeconds: 300)
    }
    
    @objc func openCompanyWebsite() {
        if let url = URL(string: "https://www.bhayapaha.in") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func quickSelectTask(_ sender: NSMenuItem) {
        if let task = sender.representedObject as? String {
            taskState.currentTask = task
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func setupOverlayWindow() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isFloatingPanel = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isMovable = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0.0
        
        let hostingView = NSHostingView(rootView: CursorOverlayView(state: taskState))
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        hostingView.frame = window.contentView?.bounds ?? .zero
        window.contentView = hostingView
        
        window.orderFront(nil)
        self.overlayWindow = window
    }
    
    func startCursorTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let now = CACurrentMediaTime()
            let mouseLoc = NSEvent.mouseLocation
            
            let dx = mouseLoc.x - self.lastMousePosition.x
            let dy = mouseLoc.y - self.lastMousePosition.y
            let moveDistance = sqrt(dx * dx + dy * dy)
            
            if moveDistance > 1.5 {
                self.lastMouseMoveTimestamp = now
                self.lastMousePosition = mouseLoc
                
                if moveDistance > 8.0 {
                    self.lastTypingTimestamp = 0
                }
            }
            
            var targetVisible = self.taskState.isVisible
            
            if targetVisible && self.taskState.autoHideWhileTyping {
                if (now - self.lastTypingTimestamp) < 1.4 {
                    targetVisible = false
                }
            }
            
            if targetVisible && self.taskState.autoHideOnIdle {
                if (now - self.lastMouseMoveTimestamp) > self.taskState.idleTimeout {
                    targetVisible = false
                }
            }
            
            let targetAlpha: CGFloat = targetVisible ? CGFloat(self.taskState.overlayOpacity) : 0.0
            let fadeSpeed: CGFloat = targetAlpha > self.currentOverlayAlpha ? 0.16 : 0.28
            
            if abs(self.currentOverlayAlpha - targetAlpha) < 0.02 {
                self.currentOverlayAlpha = targetAlpha
            } else {
                self.currentOverlayAlpha += (targetAlpha - self.currentOverlayAlpha) * fadeSpeed
            }
            
            guard let overlay = self.overlayWindow else { return }
            
            if self.currentOverlayAlpha <= 0.01 {
                if overlay.alphaValue != 0 {
                    overlay.alphaValue = 0
                }
                return
            }
            
            if overlay.alphaValue != self.currentOverlayAlpha {
                overlay.alphaValue = self.currentOverlayAlpha
            }
            if !overlay.isVisible {
                overlay.orderFront(nil)
            }
            
            let pillWidth: CGFloat = 280
            let pillHeight: CGFloat = 34
            
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            var targetX = mouseLoc.x + 18
            var targetY = mouseLoc.y - 12
            
            if targetX + pillWidth > screenFrame.maxX - 14 {
                targetX = mouseLoc.x - pillWidth - 14
            }
            
            if targetY < screenFrame.minY + 10 {
                targetY = mouseLoc.y + 20
            }
            
            if targetY + pillHeight > screenFrame.maxY - 10 {
                targetY = screenFrame.maxY - pillHeight - 10
            }
            
            overlay.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let gkm = globalKeyMonitor {
            NSEvent.removeMonitor(gkm)
        }
        if let lkm = localKeyMonitor {
            NSEvent.removeMonitor(lkm)
        }
        if let gmm = globalMouseMonitor {
            NSEvent.removeMonitor(gmm)
        }
    }
}

// ==========================================
// 11. Application Startup
// ==========================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
