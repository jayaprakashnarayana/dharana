# Dharana (🧘 Focus Tracker)

**Dharana** (Sanskrit for *concentration* or *focus*) is a lightweight, open-source macOS menu bar application designed to keep your active task floating right next to your mouse cursor. Keep your goals front-and-center as you navigate your workspaces.

---

## Core Features
* **Cursor Follower Pill**: Displays your active task inside a semi-transparent dark pill that trails your mouse cursor at 60 FPS.
* **Non-Obtrusive Click-Through**: The overlay window completely ignores mouse events (`ignoresMouseEvents = true`), so it will never block selections, clicks, or drag-and-drops underneath it.
* **Direct Task Editing**: Click and type directly on the focus card inside the popover to update your task. No extra buttons needed.
* **Pomodoro Focus Timer**: Preset timers (`15m`, `25m`, `50m`) with digital countdown display. Shows remaining time next to the cursor task pill on screen.
* **Alarms & System Notifications**: Plays a beep and displays a system alert when the timer expires, auto-switching your focus to `Break Time ☕️`.
* **Menu Bar Popover UI**: Access the SwiftUI tracker dashboard via the 🧘 (meditation emoji) icon in the status bar.
* **Status Context Menu**: Hold **`Control`** and click (or **two-finger tap** on trackpads) the status icon to open a native menu and quickly switch between your top 3 tasks without opening the popover.
* **Gemini AI Integration**: Connects directly to the Google Gemini API (`gemini-2.5-flash`) to analyze your active application window context and auto-suggest your task. Input your API key directly inside the app settings.

---

## Setup & How to Run
Open `/Users/jnaguboina/Dharana/` in Finder and double-click **`Dharana.app`**, or launch it from your Terminal:

```bash
open /Users/jnaguboina/Dharana/Dharana.app
```

*(Note: The app runs in the background as a menu bar utility, so it won't show up in your Dock. Look for the 🧘 icon in the top right of your screen).*

---

## Detailed Step-by-Step Interactions

### 1. Set/Edit Your Current Task
1. **Single-click** the 🧘 icon in the macOS menu bar (top right) to open the popover.
2. Under the **`CURRENT FOCUS`** card, click directly on the task text (defaults to *"Focus Session 🧘"*).
3. Type your new task and press **Enter** on your keyboard. Your cursor overlay updates instantly!

### 2. Run a Focus Timer (Pomodoro)
1. Open the popover and look at the **`FOCUS TIMER`** section.
2. Click one of the preset duration buttons: **`15m`** (15 minutes), **`25m`** (25 minutes), or **`50m`** (50 minutes).
3. The digital clock will start counting down in green, and the capsule next to your mouse cursor will display the remaining time (e.g., `Focus Session 🧘 [24:59]`).
4. Click **`Stop`** at any time to reset and cancel the timer.
5. When the time is up, a macOS banner notification will trigger, your computer will beep, and the task will change to `Break Time ☕️`.

### 3. Quick Switch Favorites (Single-Click)
* Once you have set a few tasks, the top 3 most recent tasks are displayed as pills under **`QUICK SWITCH`**.
* Click any pill once, and your active task shifts to that favorite focus instantly.

### 4. Right-Click Context Menu (Trackpad Shortcuts)
If you want to change focus without opening the popover:
* **Control + Click** (or **two-finger tap** on your trackpad) the 🧘 icon.
* A native menu displays your top 3 recent tasks. 
* Press the shortcut number (`1`, `2`, `3`) or click an item to switch focus.
* Click **`Quit App`** to close Dharana.

### 5. Google Gemini AI Auto-Suggestions
1. Left-click the menu bar icon and tap the **Brain icon** in the top right.
2. Paste your **Gemini API Key** (if you don't have one, click the link inside the settings panel to get a key from [Google AI Studio](https://aistudio.google.com/)).
3. Click **Save Key**.
4. Click the **AI (Sparkles) button** next to your active task. Gemini will analyze your frontmost application (e.g., Xcode, Safari, Slack) and automatically set a short task description with an emoji!
5. *(If credentials are empty, clicking the Sparkles button will simulate Gemini suggestions for demonstration).*

---

## Local Development & Compilation
If you modify `main.swift`, you can recompile the app bundle by running:

```bash
# Compile binary
swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -O main.swift -o Dharana

# Copy binary to App Bundle
cp Dharana Dharana.app/Contents/MacOS/Dharana
```
