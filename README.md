# Dharana (🧘 Focus Tracker)

**Dharana** (Sanskrit for *concentration* or *focus*) is a lightweight, open-source macOS menu bar application designed to keep your active task floating right next to your mouse cursor. Keep your goals front-and-center as you navigate your workspaces.

---

## Features
* **Cursor Follower Pill**: Displays your active task inside a semi-transparent dark pill that trails your mouse cursor at 60 FPS.
* **Non-Obtrusive Click-Through**: The overlay window completely ignores mouse events (`ignoresMouseEvents = true`), so it will never block selections, clicks, or drag-and-drops underneath it.
* **Menu Bar Popover UI**: Access the SwiftUI tracker dashboard via a checklist icon in the status bar:
  * Input custom tasks using full keyboard focus.
  * Pick from the **`QUICK SWITCH`** favorite pills (top 3 tasks) with a single tap.
  * Toggle overlay visibility on and off.
* **Status Context Menu**: Hold **`Control`** and click (or **two-finger tap** on trackpads) the status icon to open a native menu and quickly switch between your top 3 tasks without opening the popover.
* **Bedrock Claude AI Integration**: Connects to Cognito-secured API Gateway endpoints to trigger Claude AI to analyze your frontmost application context and auto-suggest your task! Includes a standalone mock simulator to test the flow out of the box.

---

## How to Run

### Run the Deployed App
Open `/Users/jnaguboina/Dharana/` in Finder and double-click **`Dharana.app`**, or launch it from your Terminal:

```bash
open /Users/jnaguboina/Dharana/Dharana.app
```

---

## Local Development & Compilation
If you modify `main.swift`, you can recompile the app bundle by running:

```bash
# Compile binary
swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -O main.swift -o Dharana

# Copy binary to App Bundle
cp Dharana Dharana.app/Contents/MacOS/Dharana
```
