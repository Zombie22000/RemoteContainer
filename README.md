<div align="center">
   <img width="217" height="217" src="./screenshots/livecontainer_icon.png" alt="Logo">
</div>

<div align="center">
  <h1><b>RemoteContainer</b></h1>
  <p><i>A LiveContainer fork with LAN remote streaming, control, and app management</i></p>
</div>

# RemoteContainer

RemoteContainer is a fork of [LiveContainer](https://github.com/LiveContainer/LiveContainer) that adds a built-in HTTP/WebSocket remote dashboard for controlling and streaming apps over your local network. It lets you browse installed apps, launch them, install IPAs, and remotely view and interact with running guest apps from any browser on the same Wi-Fi/LAN.

## Key Features

- **LAN Remote Dashboard** - A local HTTP server (on port 8080) serves a web UI accessible from any device on your network
- **App Management** - Browse, launch, and delete apps installed in RemoteContainer from the web interface
- **IPA Installation** - Upload and install `.ipa`/`.tipa` files directly through the browser
- **Live Screen Streaming** - Stream guest app windows as JPEG frames over WebSocket at ~30 FPS to a canvas in the browser
- **Remote Touch Input** - Send normalized touch/pointer events from the browser back to the iOS device to control the streamed app
- **PID-based Routing** - Stream targeting uses process IDs for precise mapping to running guest app windows
- **Automatic Server Startup** - The remote server starts automatically on app launch

## How It Works

### Architecture

1. **Server (`RemoteServerManager`)** - Runs an `NWListener` on port 8080 with WebSocket support. Handles HTTP requests for the dashboard, API endpoints (`/api/apps`, `/api/launch`, `/api/delete`, `/api/install`), and upgrades WebSocket connections at `/stream`.
2. **Web Dashboard (`RemoteDashboard.html`)** - A self-contained HTML/JS interface served by the server. Lists apps, provides install/launch/delete actions, and renders the streaming view with a canvas + WebSocket client.
3. **Frame Capture (`FrameCapturer`/`ViewStreamer`)** - Captures frames from the target guest app window using `CADisplayLink` + `UIGraphicsImageRenderer`, encodes them as JPEG, and broadcasts them to connected WebSocket clients.
4. **Touch Synthesis** - Browser pointer/touch events are normalized to [0,1] coordinates and sent over WebSocket as JSON, then dispatched to the iOS view hierarchy via synthetic touch events.

### Usage

1. Launch RemoteContainer on your iOS device
2. The remote server starts automatically on port 8080
3. On another device on the same network, open `http://<device-ip>:8080/` in your browser
4. Browse installed apps, install IPAs, or click "Launch on iPhone" to open a streaming window
5. Use the streamed canvas to view and interact with the app remotely

### WebSocket Protocol

- **Connection**: `ws://<host>:8080/stream?pid=<processId>`
- **Server → Client**: Binary WebSocket frames containing JPEG image data
- **Client → Server**: JSON messages with touch events `{type: 'touchesBegan'|'touchesMoved'|'touchesEnded', x: 0.0-1.0, y: 0.0-1.0}`

## Credits

RemoteContainer is based on [LiveContainer](https://github.com/LiveContainer/LiveContainer). All original LiveContainer features and functionality are preserved.
