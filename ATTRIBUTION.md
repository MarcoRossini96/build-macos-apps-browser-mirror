# Attribution and provenance

## Upstream project

This repository is a community-maintained derivative of OpenAI's public
[`build-macos-apps` plugin](https://github.com/openai/plugins/tree/main/plugins/build-macos-apps),
from the [`openai/plugins`](https://github.com/openai/plugins) repository.

The upstream plugin manifest identifies the author as OpenAI and declares the
license as MIT. The upstream workflows retained here—including its macOS build,
test, signing, SwiftUI, AppKit, window-management, and telemetry skills—remain
attributed to that project. This repository preserves the MIT license and this
notice alongside the derivative work.

## Derivative additions

The following material was added for this repository by Marco Rossini in 2026:

- the `macos-window-browser` skill;
- its native ScreenCaptureKit helper and localhost-only browser viewer;
- the public marketplace metadata, installation instructions, and security
  documentation for the mirror;
- the original repository cover at `assets/browser-mirror-cover.png`.

The mirror is intentionally read-only. It uses a capability URL bound to
`127.0.0.1`; it does not persist frames or transmit them to a remote service.

## Asset record

| Asset | Provenance |
| --- | --- |
| `assets/app-icon.png` | Retained from the upstream `build-macos-apps` plugin assets. |
| `assets/build-macos-apps-small.svg` | Retained from the upstream `build-macos-apps` plugin assets. |
| `assets/browser-mirror-cover.png` | Original artwork generated for this repository with OpenAI image generation on 21 August 2026. It contains no third-party logos, product names, or copied UI. |

## Names and affiliation

OpenAI and Codex are trademarks of their respective owners. Their use here is
only nominative: it identifies the upstream project and the Codex plugin
environment. This independent repository is not created by, affiliated with,
or endorsed by OpenAI.

For the concise distribution notice, see [NOTICE](NOTICE). For permissions and
conditions, see the [MIT License](LICENSE).
