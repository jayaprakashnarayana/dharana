<p align="center">
  <img src="assets/app_icon.png" width="128" height="128" alt="Dharana App Icon" />
</p>

<h1 align="center">Dharana (🧘 Focus Tracker)</h1>

<p align="center">
  <b>A lightweight, ultra-smooth macOS focus companion that keeps your active goal floating right beside your cursor.</b>
</p>

<p align="center">
  Developed with ❤️ by <a href="https://www.bhayapaha.in"><b>Bhayapaha Intelligence</b></a>
</p>

<p align="center">
  <a href="https://www.bhayapaha.in">
    <img src="https://img.shields.io/badge/Company-Bhayapaha%20Intelligence-4F46E5?style=for-the-badge&logo=globe&logoColor=white" alt="Bhayapaha Intelligence" />
  </a>
  <a href="https://buymeacoffee.com/9o0rFmKygY">
    <img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy Me A Coffee" />
  </a>
  <img src="https://img.shields.io/badge/Platform-macOS%2012.0+-black?style=for-the-badge&logo=apple" alt="macOS 12+" />
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift" />
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License" />
</p>

---

## 📸 Screenshots

<p align="center">
  <img src="assets/dashboard.jpg" width="410" alt="Dharana Dashboard UI" />
  &nbsp;&nbsp;
  <img src="assets/cursor_pill.jpg" width="410" alt="Cursor Pill Overlay" />
</p>

---

## ✨ Core Features

* **🧘 60 FPS Cursor Follower Pill**: Displays your active task and countdown in a semi-transparent dark pill that smoothly trails your mouse cursor across all macOS Spaces.
* **⌨️ Smart Typing Auto-Hide**: Automatically vanishes the moment you type in VS Code, Xcode, Safari, Terminal, or Slack so it **never** obstructs your code or text. Fades back in seamlessly when you move your mouse.
* **⏳ Inactivity Idle Fade-Out**: Fades to zero opacity when the cursor is stationary for 3 seconds, keeping your screen clean and distraction-free while reading.
* **📐 Display Edge & Boundary Avoidance**: Dynamically flips position (left/right, above/below) when approaching screen edges to avoid cursor clipping.
* **⏱️ Pomodoro Focus Timer**: Quick preset buttons (`15m`, `25m`, `50m`) plus **custom duration input** with live digital countdown display, macOS notifications, and sound alerts on session completion.
* **🧠 Google Gemini AI Integration**: Analyzes your active application context to auto-suggest concise, emoji-tagged focus milestones via `gemini-2.5-flash`.
* **🔒 Hardware-Backed AES-256 Encryption**: Stores your API key securely with zero system password popups.
* **⚡ 0.0% CPU & Low-Power Idle Mode**: Uses adaptive event listeners and GPU-cached rendering to eliminate idle battery drain on Apple Silicon & Intel Macs.
* **🛡️ Non-Obtrusive Click-Through**: Built with `ignoresMouseEvents = true` so the overlay never intercepts mouse clicks, selections, or drag-and-drop actions underneath it.

---

## 🚀 Quick Download & Installation

### Option 1: Download Pre-built Installer (Recommended)
Download the latest pre-packaged **`.dmg`** or **`.zip`** installer from the **[Releases](https://github.com/jayaprakashnarayana/dharana/releases)** tab.

1. Open **`Dharana-Installer.dmg`**.
2. Drag **Dharana.app** into your **Applications** folder.
3. Launch Dharana from Spotlight (`Cmd + Space > Dharana`) or your Applications folder.

*(Note: On first open outside the Mac App Store, if prompted by macOS Gatekeeper, simply **Right-Click > Open**, then click **Open**).*

---

## 🛠️ Building From Source

### 1. Build & Run Locally
```bash
# Clone the repository
git clone https://github.com/jayaprakashnarayana/dharana.git
cd dharana

# Compile and launch
swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -O main.swift -o Dharana
cp Dharana Dharana.app/Contents/MacOS/Dharana
open Dharana.app
```

### 2. Generate `.dmg` and `.zip` Distributables
To build standalone release installers:
```bash
chmod +x build_dmg.sh
./build_dmg.sh
```
Installers will be generated in `dist/`:
* 💿 **`dist/Dharana-Installer.dmg`**
* 📦 **`dist/Dharana-macOS.zip`**

---

## 🎯 Usage Guide

1. **Set Focus**: Click the Dharana Dock icon or Menu Bar item (`⚡️ DHARANA`), type your active task under **`WHAT ARE YOU FOCUSING ON?`**, and press **Enter**.
2. **Start Pomodoro**: Click `15m`, `25m`, `50m` or type a **custom number of minutes** and click **Set Custom Time**.
3. **AI Suggestion**: Click the **Sparkles (✨)** button to have Gemini AI auto-detect what you're working on and title your session.
4. **Settings & Customization**: Click the **Gear (⚙️)** icon to customize typing auto-hide, idle delay, pill opacity, or configure your Gemini API Key.

---

## 🏢 About Bhayapaha Intelligence

**Dharana** is developed and maintained by **[Bhayapaha Intelligence](https://www.bhayapaha.in)**. We build human-centered AI systems, productivity tools, and intelligent macOS applications.

* 🌐 **Website**: [www.bhayapaha.in](https://www.bhayapaha.in)
* ☕️ **Support the Developer**: [buymeacoffee.com/9o0rFmKygY](https://buymeacoffee.com/9o0rFmKygY)

---

## 📄 License
This project is open-source under the [MIT License](LICENSE) &copy; 2026 Bhayapaha Intelligence.
