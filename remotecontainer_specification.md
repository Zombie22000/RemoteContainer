# Master AI Codex Prompt: RemoteContainer (LiveContainer Web Extension Fork)

> **Role:** You are an expert iOS Swift/Objective-C developer, C/C++ reverse engineer, and WebRTC system engineer.
> **Task:** Modify the open-source [LiveContainer](https://github.com/khanhduytran0/LiveContainer) codebase to build **RemoteContainer**, a single-user fork that turns an iOS device running containerized `.ipa` applications into a headless web-accessible app server for desktop and mobile web browsers.

## 1. Project Overview & Scope

* **Name:** RemoteContainer

* **Target OS:** iOS 15.0+ (Host Server), Modern Desktop Web Browsers (Chrome, Edge, Safari, Firefox) / Mobile Browsers (Client)

* **Model:** Single-user self-hosted local network bridge (No multi-tenant authentication or complex cloud proxying required).

* **Branding:** Green color swap of standard LiveContainer assets (`#34C759` / `#30D158` emerald gradients).

## 2. Architecture & Technical Requirements

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          iOS HOST DEVICE                                │
│                                                                         │
│  ┌───────────────────────┐             ┌─────────────────────────────┐  │
│  │ Guest iOS Container   │             │ Embedded Swift HTTP Server  │  │
│  │ (LiveContainer Guest) │             │ (GCDWebServer / CocoaHTTPServer) │
│  └──────────┬────────────┘             └──────────────┬──────────────┘  │
│             │                                         │                 │
│             ▼                                         ▼                 │
│  ┌───────────────────────┐             ┌─────────────────────────────┐  │
│  │ Screen Frame Capture  │             │ WebRTC / WebSocket Gateway  │  │
│  │ & CoreAudio Intercept │────────────>│ (Opus Audio + H.264/noVNC)  │  │
│  └───────────────────────┘             └──────────────┬──────────────┘  │
└───────────────────────────────────────────────────────┼─────────────────┘
                                                        │ Local Network / USB
                                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          CLIENT BROWSER                                 │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ Main Web Dashboard (`http://<iphone-ip>:8080`)                    │  │
│  │ ├─ App Grid (Recreates LiveContainer UI)                          │  │
│  │ └─ "Run on Desktop" Button -> Opens Popup Stream Window           │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

```

## 3. Detailed Component Specifications

### Feature A: Embedded Web Server & App Dashboard

1. Integrate an embedded lightweight HTTP/WebSocket server directly into the iOS LiveContainer main process (e.g., using `GCDWebServer` or custom Swift `NWListener`).

2. Serve a single-page web app recreating the native LiveContainer interface using Tailwind CSS and modern JavaScript:

   * **App Grid:** List all installed `.ipa` containers with app icons, bundle IDs, and container state.

   * **Launch Options:** Provide two main buttons per app:

     * `Run on Desktop`: Opens a standalone JavaScript popup window (`/stream?app=<bundleId>&mode=desktop`).

     * `Run on Mobile`: Navigates directly to a full-viewport borderless stream window (`/stream?app=<bundleId>&mode=mobile`).

### Feature B: Screen Capture & VNC/WebRTC Video Engine

1. Implement a frame buffer capture engine hooking into the guest container view hierarchy:

   * Use `CADisplayLink` or metal surface capture to extract rendered frames from the active container context.

2. Compress frames and stream via either a low-latency WebRTC peer connection or a fallback WebSocket + HTML5 `noVNC` Canvas pipeline.

3. Optimize for target 60 FPS streaming on standard local 802.11ac / Wi-Fi 6 networks or USB `usbmuxd` reverse tunnels.

### Feature C: Low-Latency Audio Streaming Pipeline

1. Hook into `AVAudioEngine` / `CoreAudio` session for the target containerized app process to capture system audio output.

2. Encode audio buffers to the **Opus** format at 48kHz.

3. Stream audio in sync with video frames over WebRTC/WebSocket.

4. **Mobile Browser Autoplay Fix:**

   * In mobile client mode (`/stream?mode=mobile`), render a floating overlay badge in the top-right corner: `🔊 Tap to Unmute`.

   * On tap, trigger `audioContext.resume()` and fade out the floating badge using CSS transitions before unmounting it from the DOM.

### Feature D: Interactive Controls & Desktop Topbar

1. Render a persistent glassmorphic topbar in Desktop mode with the following items:

   * **Resolution Dropdown:**

     * `Auto-Adapt (Default)`: Dynamically updates the guest container render viewport to match client window resize events via standard `window.onresize` hooks.

     * `iPhone 15/16 Pro (393 × 852)`

     * `iPad Air (820 × 1180)`

   * **Mouse-to-Touch Mapper:** Intercept `mousedown`, `mousemove`, `mouseup`, and drag gestures on the desktop canvas and map them directly into simulated iOS `UITouch` events sent back over the WebSocket control channel.

   * **Latency & FPS Counter:** Real-time ping display.

### Feature E: Concurrent Multi-App Instances

1. Leverage LiveContainer's multi-process isolation capability.

2. Support spawning independent streaming pipelines on dynamic ports or sub-paths (`/stream/app1`, `/stream/app2`) so multiple iOS apps can run in separate floating windows on the desktop client.

### Feature F: Green Theme Branding

1. Replace standard LiveContainer blue color tokens (`#007AFF`, `#5AC8FA`) across all iOS Storyboards, SwiftUI views, and Web UI stylesheets with mint/emerald green equivalents (`#34C759`, `#30D158`).

2. Update application icon assets to reflect the emerald gradient scheme.

## 4. Step-by-Step Implementation Instructions for Codex

1. **Step 1: Web Server Integration**

   * Add `GCDWebServer` or equivalent Swift server package to `Podfile` / Swift Package Manager.

   * Create `RemoteServerManager.swift` to initialize the HTTP/WebSocket listener on app startup on port `8080`.

2. **Step 2: Web Dashboard UI Construction**

   * Build an single-file HTML/JS app served at root `/`.

   * Implement REST endpoints `/api/apps` (returns JSON list of installed containers) and `/api/launch` (triggers app start).

3. **Step 3: Canvas Video/Audio Engine**

   * Build `RemoteStreamEngine.m` to hook guest process display layers.

   * Set up WebRTC client/server handshake signaling over WebSockets.

4. **Step 4: Control Input Injection**

   * Write touch translation helpers inside `RemoteInputHandler.swift` to simulate `UIEvent` instances from incoming WebSocket JSON payloads containing normalized `(x, y)` coordinates.

5. **Step 5: Test Verification**

   * Build the iOS project, run on an iOS test device, connect from any modern web browser (`http://<device-ip>:8080`), launch an app in desktop mode, test mouse navigation, resolution changes, and WebAudio playback.

**Generate the complete code modifications, new Swift/Objective-C files, and web dashboard HTML template needed to complete this implementation.**