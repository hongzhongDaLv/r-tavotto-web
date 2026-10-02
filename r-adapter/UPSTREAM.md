# Tavotto R derivative

Upstream: https://github.com/Tavotto/Tavotto

Pinned commit: 13886a0b7ebf9073c31023a923833a74e7eebbe5

License: AGPL-3.0-only; original LICENSE and copyright notices retained.

Changes dated 2026-09-22: added r-adapter/, web/src/r/, web/r.html and web/vite.r.config.ts. Original canvas, stores, inspectors and interaction handlers are reused without rewriting. This is a local experimental derivative, not an official Tavotto release.

The R adapter currently targets single-panel ggplot2. It retains a plot in a live R process, accepts full override lists and generates SVG/PDF and a reproducible R script. Codex packaging and desktop packaging are separate integration work; a browser smoke test alone does not establish either.

2026-09-23 update: Windows WebView2 EXE and MCP plugin added. Plain R text capability added to shared TextActions/QuickEdit/EditableField, and R source-action guard added. Full current status: ../DELIVERY.md. Original Tauri build remains unbuilt.
