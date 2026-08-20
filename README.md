# Build macOS Apps + Browser Mirror Plugin

An open-source Codex plugin derived from OpenAI's MIT-licensed `build-macos-apps` plugin. It adds a high-density, localhost-only browser mirror for one native macOS app window.

## Install

This plugin requires macOS 14 or later, Xcode Command Line Tools, and Screen
Recording permission for the terminal or Codex process when using the mirror.

```bash
codex plugin marketplace add MarcoRossini96/build-macos-apps-browser-mirror
codex plugin add build-macos-apps-browser-mirror --marketplace marco-macos-plugins
```

The mirror intentionally binds only to `127.0.0.1`, uses a random capability
URL, and never writes frames to disk or sends them to an external service.

It currently includes these skills:

- `build-run-debug`
- `test-triage`
- `signing-entitlements`
- `swiftpm-macos`
- `packaging-notarization`
- `swiftui-patterns`
- `liquid-glass`
- `window-management`
- `appkit-interop`
- `view-refactor`
- `telemetry`
- `macos-window-browser` (added by this derivative)

## What It Covers

- discovering local Xcode workspaces, projects, and Swift packages
- building and running macOS apps with shell-first desktop workflows
- creating one project-local `script/build_and_run.sh` entrypoint and wiring `.codex/environments/environment.toml` so the Codex app Run button works
- implementing native macOS SwiftUI scenes, menus, settings, toolbars, and multiwindow flows
- adopting modern macOS Liquid Glass and design-system guidance with standard SwiftUI structures, toolbars, search, controls, and custom glass surfaces
- tailoring SwiftUI windows with title/toolbar styling, material-backed container backgrounds, minimize/restoration behavior, default and ideal placement, borderless window style, and launch behavior
- bridging into AppKit for representables, responder-chain behavior, panels, and other desktop-only needs
- refactoring large macOS view files toward stable scene, selection, and command structure
- adding lightweight `Logger` / `os.Logger` instrumentation for windows, sidebars, menu commands, and menu bar actions
- reading and verifying runtime events with Console, `log stream`, and process logs
- triaging failing unit, integration, and UI-hosted macOS tests
- debugging launch failures, crashes, linker problems, and runtime regressions
- inspecting signing identities, entitlements, hardened runtime, and Gatekeeper issues
- preparing packaging and notarization workflows for distribution

## What It Does Not Cover

- iOS, watchOS, or tvOS simulator control
- desktop UI automation
- App Store Connect release management
- pixel-perfect visual design or design-system generation

## Plugin Structure

The repository root is the plugin root, with this shape:

- `.codex-plugin/plugin.json`
  - required plugin manifest
  - defines plugin metadata and points Codex at the plugin contents

- `agents/`
  - plugin-level agent metadata
  - currently includes `agents/openai.yaml` for the OpenAI surface

- `commands/`
  - reusable workflow entrypoints for common macOS development tasks

- `skills/`
  - the actual skill payload
  - each skill keeps the normal skill structure (`SKILL.md`, optional
    `agents/`, `references/`, `assets/`, `scripts/`)

## Notes

This plugin is currently skills-first at the plugin level. It does not ship a
plugin-local `.mcp.json`, matching the public `plugins/build-ios-apps` shape.

The default posture is shell-first. Unlike the iOS build plugin, this plugin
does not assume simulator tooling or touch-driven UI inspection for its main
workflows. The core execution model leans on `xcodebuild`, `swift`, `open`,
`lldb`, `codesign`, `spctl`, `plutil`, and `log stream`, with a compact desktop
UI layer for native SwiftUI scene design, AppKit interop, and macOS-specific
refactoring.

## Browser mirror

After launching a native app, run:

```bash
skills/macos-window-browser/scripts/macos_window_browser.sh --app-name "CodexAppFrontend"
```

Open the printed `http://127.0.0.1:<port>/<token>/` URL in Codex Browser. The viewer is an intentionally clean, read-only preview: no selection rectangles or UI annotations are drawn over the native window. The mirror requests a 2× source buffer, capped at 2560 pixels wide, with high-quality JPEG encoding so compact text remains legible in the browser. The browser retrieves its frames through ScreenCaptureKit without writing them to disk or transmitting them over the network. macOS Screen Recording permission is required for the terminal or Codex process.

## License and attribution

Licensed under the [MIT License](LICENSE). See [NOTICE](NOTICE) for the
upstream OpenAI plugin attribution.
