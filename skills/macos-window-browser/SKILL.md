---
name: macos-window-browser
description: Show and interact with a native macOS app window in Codex Browser through a local loopback mirror. Use when the user wants a macOS Swift or SwiftUI app visible in a browser similarly to an iOS Simulator preview.
---

# macOS Window Browser

Mirror a real native macOS window to a browser page served only on `127.0.0.1`. The page refreshes the target window continuously at Retina density (capped at 2560 pixels wide) in a clean, read-only preview without annotation rectangles.

## Workflow

1. Build and launch the macOS app with `build-run-debug` or another project-specific run command.
2. Identify the application process name; this is commonly its executable product name, such as `CodexAppFrontend`.
3. Start the mirror, keeping its terminal running:

   ```bash
   skills/macos-window-browser/scripts/macos_window_browser.sh --app-name "CodexAppFrontend"
   ```

4. Open the exact `http://127.0.0.1:<port>/` address printed by the command in Codex Browser.
5. Confirm that the browser displays a real native window frame without any browser-drawn selection overlays.
6. Use the user's browser comment or supplied coordinates as UI context; the viewer never activates the native app itself.
7. End the mirror with `Ctrl-C`; it removes its temporary helper automatically.

## Permissions and safety

- The terminal or Codex process may need **Screen Recording** permission to capture frames.
- If capture is unavailable, direct the user to **System Settings → Privacy & Security → Screen & System Audio Recording**. Do not alter privacy settings programmatically.
- The server is bound to `127.0.0.1`, not to a LAN interface. Do not expose it through a tunnel or a public URL unless the user explicitly asks.
- Mirror only the window selected by `--app-name`; do not capture the entire desktop. Do not collect field values, secure text, clipboard contents, or any keystrokes.

## Options

```bash
skills/macos-window-browser/scripts/macos_window_browser.sh --app-name "CodexAppFrontend" --port 41731
skills/macos-window-browser/scripts/macos_window_browser.sh --app-name "CodexAppFrontend" --title "Editor"
```
