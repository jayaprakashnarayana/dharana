import Cocoa
import SwiftUI
import Combine
import UserNotifications
import Security

// 1. Hardware-Backed Encrypted Keychain Service for Secure API Key Storage
class KeychainHelper {
    private static let service = "com.dharana.focus-tracker"
    private static let account = "gemini_api_key"
    
    static func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove existing item
        let queryDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(queryDelete as CFDictionary)
        
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        
        // Add encrypted entry
        let queryAdd: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(queryAdd as CFDictionary, nil)
    }
    
    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data, let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        // Automatic migration from legacy unencrypted UserDefaults plist
        if let legacyKey = UserDefaults.standard.string(forKey: "dharana_gemini_api_key"), !legacyKey.isEmpty {
            save(key: legacyKey)
            UserDefaults.standard.removeObject(forKey: "dharana_gemini_api_key")
            return legacyKey
        }
        
        return ""
    }
}

// 2. TaskState (ObservableObject) to coordinate active task and timer between Popover and Overlay
class TaskState: ObservableObject {
    @Published var currentTask: String = "Focus Session 🧘"
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
    
    // Secure Keychain API Key
    @Published var isGeneratingAI: Bool = false
    @Published var geminiApiKey: String = KeychainHelper.load()
    
    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "dharana_recent_tasks"), !saved.isEmpty {
            self.recentTasks = saved
        } else {
            self.recentTasks = [
                "Coding 💻",
                "Writing 📝",
                "Debugging 🐛",
                "Meetings 🤝",
                "Coffee Break ☕️"
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
    
    // Timer State
    @Published var timerRemaining: Int = 0
    @Published var isTimerActive: Bool = false
    private var countdownTimer: AnyCancellable?
    
    func saveSettings() {
        KeychainHelper.save(key: geminiApiKey)
        UserDefaults.standard.set(autoHideWhileTyping, forKey: "dharana_auto_hide_typing")
        UserDefaults.standard.set(autoHideOnIdle, forKey: "dharana_auto_hide_idle")
        UserDefaults.standard.set(idleTimeout, forKey: "dharana_idle_timeout")
        UserDefaults.standard.set(overlayOpacity, forKey: "dharana_overlay_opacity")
    }
    
    // Timer Actions
    func startTimer(durationInSeconds: Int) {
        stopTimer()
        timerRemaining = durationInSeconds
        isTimerActive = true
        
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
    
    func stopTimer() {
        isTimerActive = false
        timerRemaining = 0
        countdownTimer?.cancel()
        countdownTimer = nil
    }
    
    private func timerExpired() {
        stopTimer()
        currentTask = "Break Time ☕️"
        NSSound.beep()
        sendNotification()
    }
    
    private func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Time's Up! 🧘"
        content.body = "Your focus session is complete. Time to take a break!"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "DharanaTimerExpired", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error:", error)
            }
        }
    }
}

// 3. Ephemeral, Zero-Disk-Footprint Gemini AI Service with Header Authentication
class AIService {
    // Ephemeral session avoids writing API responses or credentials to disk caches
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
        
        // Security Fix: Avoid passing API keys in query string (keeps proxy/server logs clean)
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key") // Secure header auth
        
        // Security Fix: Sanitize context to prevent prompt injection and keep payloads tight
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

// 3. Overlay view that follows the cursor
struct CursorOverlayView: View {
    @ObservedObject var state: TaskState
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isTimerActive ? Color.green : Color.indigo)
                .frame(width: 6, height: 6)
            
            Text(state.currentTask)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundColor(.white)
                .lineLimit(1)
            
            if state.isTimerActive {
                Text(formatTime(state.timerRemaining))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.8))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// 4. Popover SwiftUI view for selecting / entering tasks and managing timers
struct TaskPopoverView: View {
    @ObservedObject var state: TaskState
    @State private var showAISettings: Bool = false
    
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
                .help("API Settings")
            }
            
            // Collapsible Settings (Gemini & Overlay Behavior)
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
                        
                        Text("v1.0")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Active task card (Directly editable!)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("FOCUS TIMER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 8) {
                    // Digital Time Display
                    Text(formatTime(state.timerRemaining))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(state.isTimerActive ? .green : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                    
                    // Presets
                    ForEach([15, 25, 50], id: \.self) { mins in
                        Button("\(mins)m") {
                            state.startTimer(durationInSeconds: mins * 60)
                            updateRecentTasks(with: state.currentTask)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                    
                    // Stop Button
                    if state.isTimerActive {
                        Button("Stop") {
                            state.stopTimer()
                        }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(6)
                    }
                }
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
                .frame(height: 120)
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
        .frame(minHeight: showAISettings ? 620 : 450)
        .background(VisualEffectView().edgesIgnoringSafeArea(.all))
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

// 5. NSVisualEffectView helper for beautiful native popover blurring
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

// 6. App Delegate to manage lifecycle, StatusItem, and windows
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var overlayWindow: NSWindow?
    let taskState = TaskState()
    var timer: Timer?
    
    // Keyboard, Mouse Activity & Low-Power Idle Tracking
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?
    var globalMouseMonitor: Any?
    var lastTypingTimestamp: TimeInterval = 0
    var lastMouseMoveTimestamp: TimeInterval = CACurrentMediaTime()
    var lastMousePosition: NSPoint = .zero
    var currentOverlayAlpha: CGFloat = 0.0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show in dock so it's always accessible
        NSApp.setActivationPolicy(.regular)
        
        // Explicitly set the Dock application icon
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "Dharana", withExtension: "icns"),
           let img = NSImage(contentsOf: iconUrl) {
            NSApp.applicationIconImage = img
        } else if let fallbackImg = NSImage(contentsOfFile: "/Users/jnaguboina/Dharana/Dharana.icns") {
            NSApp.applicationIconImage = fallbackImg
        }
        
        // Request notifications permission for timer alarms
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        setupStatusItem()
        setupSettingsWindow()
        setupOverlayWindow()
        setupEventMonitors()
        startCursorTracking()
    }
    
    func setupEventMonitors() {
        // Global key monitor: captures typing across external apps (VS Code, Xcode, Safari, etc.)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            self?.lastTypingTimestamp = CACurrentMediaTime()
        }
        
        // Local key monitor: captures typing inside Dharana's own windows
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.lastTypingTimestamp = CACurrentMediaTime()
            return event
        }
        
        // Global mouse monitor: keeps mouse activity timestamp fresh without excessive polling
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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 490),
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
        
        if topTasks.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent tasks", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit App", action: #selector(quitApp), keyEquivalent: "q"))
        
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
        window.ignoresMouseEvents = true // Click-through
        window.level = .screenSaver // Above other windows
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
        // High-efficiency adaptive loop
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let now = CACurrentMediaTime()
            let mouseLoc = NSEvent.mouseLocation
            
            // Mouse movement delta calculation
            let dx = mouseLoc.x - self.lastMousePosition.x
            let dy = mouseLoc.y - self.lastMousePosition.y
            let moveDistance = sqrt(dx * dx + dy * dy)
            
            if moveDistance > 1.5 {
                self.lastMouseMoveTimestamp = now
                self.lastMousePosition = mouseLoc
                
                // Deliberate cursor motion clears typing suppression immediately
                if moveDistance > 8.0 {
                    self.lastTypingTimestamp = 0
                }
            }
            
            // Visibility determination
            var targetVisible = self.taskState.isVisible
            
            // 1. Suppress while actively typing
            if targetVisible && self.taskState.autoHideWhileTyping {
                if (now - self.lastTypingTimestamp) < 1.4 {
                    targetVisible = false
                }
            }
            
            // 2. Suppress when cursor is stationary beyond idle timeout
            if targetVisible && self.taskState.autoHideOnIdle {
                if (now - self.lastMouseMoveTimestamp) > self.taskState.idleTimeout {
                    targetVisible = false
                }
            }
            
            // Fast fade out, smooth fade in
            let targetAlpha: CGFloat = targetVisible ? CGFloat(self.taskState.overlayOpacity) : 0.0
            let fadeSpeed: CGFloat = targetAlpha > self.currentOverlayAlpha ? 0.16 : 0.28
            
            if abs(self.currentOverlayAlpha - targetAlpha) < 0.02 {
                self.currentOverlayAlpha = targetAlpha
            } else {
                self.currentOverlayAlpha += (targetAlpha - self.currentOverlayAlpha) * fadeSpeed
            }
            
            guard let overlay = self.overlayWindow else { return }
            
            // Memory & GPU efficiency: do not compute layout when alpha is 0
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
            
            // Smart Screen Boundary & Flipping Avoidance
            let pillWidth: CGFloat = 280
            let pillHeight: CGFloat = 34
            
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            var targetX = mouseLoc.x + 18
            var targetY = mouseLoc.y - 12
            
            // Flip left if near right edge of screen
            if targetX + pillWidth > screenFrame.maxX - 14 {
                targetX = mouseLoc.x - pillWidth - 14
            }
            
            // Flip above if near bottom edge of screen
            if targetY < screenFrame.minY + 10 {
                targetY = mouseLoc.y + 20
            }
            
            // Clamp top boundary
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

// 7. Application Startup
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
