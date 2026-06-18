import Cocoa
import SwiftUI
import Combine
import UserNotifications

// 1. TaskState (ObservableObject) to coordinate active task and timer between Popover and Overlay
class TaskState: ObservableObject {
    @Published var currentTask: String = "Focus Session 🧘"
    @Published var isVisible: Bool = true
    @Published var recentTasks: [String] = [
        "Coding 💻",
        "Writing 📝",
        "Debugging 🐛",
        "Meetings 🤝",
        "Coffee Break ☕️"
    ]
    
    // Timer State
    @Published var timerRemaining: Int = 0
    @Published var isTimerActive: Bool = false
    private var countdownTimer: AnyCancellable?
    
    // Gemini AI Integration Settings
    @Published var isGeneratingAI: Bool = false
    @Published var geminiApiKey: String = UserDefaults.standard.string(forKey: "dharana_gemini_api_key") ?? ""
    
    func saveSettings() {
        UserDefaults.standard.set(geminiApiKey, forKey: "dharana_gemini_api_key")
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

// 2. Gemini AI Integration Service (connects Swift directly to the Google Gemini API)
class AIService {
    static func suggestTask(apiKey: String, context: String, completion: @escaping (String?) -> Void) {
        guard !apiKey.isEmpty else {
            completion(nil)
            return
        }
        
        // Using Gemini 2.5 Flash as the standard fast, lightweight model
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        // Formulate prompt for Gemini
        let prompt = "Suggest a single, active, action-oriented task description (max 4 words, include 1 matching emoji at the end) describing what a developer is doing based on this context: '\(context)'. Output ONLY the task name, nothing else."
        
        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": 20
            ]
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(nil)
            return
        }
        request.httpBody = httpBody
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            // Parse Google Gemini generateContent response JSON
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
                if let rawString = String(data: data, encoding: .utf8) {
                    print("Raw Gemini API error or response:", rawString)
                }
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
            HStack {
                Text("Dharana Focus Tracker")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: {
                    withAnimation {
                        showAISettings.toggle()
                    }
                }) {
                    Image(systemName: "brain.headset")
                        .foregroundColor(state.geminiApiKey.isEmpty ? .gray : .indigo)
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Gemini API Settings")
            }
            
            // Collapsible Gemini Config settings
            if showAISettings {
                VStack(spacing: 8) {
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
                }
                .padding(8)
                .background(Color.white.opacity(0.04))
                .cornerRadius(6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Active task card (Directly editable!)
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT FOCUS (CLICK TEXT TO EDIT)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 8) {
                    TextField("Enter active focus...", text: $state.currentTask, onCommit: {
                        updateRecentTasks(with: state.currentTask)
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    
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
        .frame(width: 280, height: showAISettings ? 470 : 440)
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
                alert.informativeText = "To trigger real Gemini suggestions, configure your Gemini API Key inside the Settings panel (brain icon)."
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
    var popover: NSPopover?
    var overlayWindow: NSWindow?
    let taskState = TaskState()
    var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide standard dock icon since this is a utility/menu bar app
        NSApp.setActivationPolicy(.accessory)
        
        // Request notifications permission for timer alarms
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        setupStatusItem()
        setupOverlayWindow()
        startCursorTracking()
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Dharana Focus Tracker")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TaskPopoverView(state: taskState))
        self.popover = popover
    }
    
    @objc func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            togglePopover(sender)
        }
    }
    
    func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if let popover = popover {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 50),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true // Click-through!
        window.level = .statusBar // Float above other windows
        window.isMovable = false
        window.hasShadow = false
        
        let hostingView = NSHostingView(rootView: CursorOverlayView(state: taskState))
        hostingView.frame = window.contentView?.bounds ?? .zero
        window.contentView = hostingView
        
        window.orderFront(nil)
        self.overlayWindow = window
    }
    
    func startCursorTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            guard self.taskState.isVisible else {
                self.overlayWindow?.orderOut(nil)
                return
            }
            
            if self.overlayWindow?.isVisible == false {
                self.overlayWindow?.orderFront(nil)
            }
            
            let mouseLoc = NSEvent.mouseLocation
            
            let offsetWindowX = mouseLoc.x + 18
            let offsetWindowY = mouseLoc.y - 12
            
            self.overlayWindow?.setFrameOrigin(NSPoint(x: offsetWindowX, y: offsetWindowY))
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
}

// 7. Application Startup
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
