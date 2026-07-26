# 08 — Text Compare

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop application screen, Text Compare main populated result state
Input images: Image 1 is a style reference only; preserve its Riffa product language, sidebar proportions, shared comparison chrome, density, near-black surface ladder, hairline borders, spacing rhythm, and compact native macOS control treatment. Generate a new page, do not edit or reproduce Image 1 pixel-for-pixel.
Primary request: Design the Riffa “Text Compare” page as a shippable 1536×1024 landscape macOS UI. Show the complete app window with macOS traffic lights and title “Riffa”, persistent left sidebar, shared page header, control toolbar, two resource path cards, two synchronized text editor panes, a narrow transfer/action gutter, difference overview rail, and bottom status bar. This must be the populated main result state.
Navigation: sidebar brand text “Riffa”; sections “COMPARE” and “MERGE & SYNC”; rows including “Folder Compare”, selected “Text Compare”, “Text Patch”, “Hex Compare”, “Image Compare”, “PDF Compare”, “Metadata Compare”, “Table Compare”, “Folder Merge”, “Folder Sync”, “Text Merge”. Selected row uses a restrained lavender surface highlight and a monochrome document icon.
Header and controls: page title “Text Compare”; subtitle “Two-way, line-aligned comparison”; actions “Save Session”, “Compare Options”, previous/next difference icon buttons, and a search field containing “version”. Second row controls: “Compare Content”, “Ignore Whitespace”, “View Side-by-Side”, “Encoding UTF-8”, checked “Show Line Numbers”, unchecked “Show Whitespace”, checked “Show Unchanged”.
Paths: left “/Users/alex/projects/riffa/config.json”; right “/Users/alex/projects/riffa/config.remote.json”, each in a surface-2 path card with a monochrome file icon and ellipsis accessory.
Data content: readable monospaced JSON with line numbers 1–21. Show unchanged context plus exactly three aligned differences: line 4 left `"version": "1.4.0",` marked with a visible minus glyph and muted red semantic row, right `"version": "1.5.0",` marked with plus glyph and muted green semantic row; line 9 left `"merge": false` versus right `"merge": true`; line 13 left `"logs": "/var/log/riffa",` versus right `"logs": "/var/log/riffa/app",`. Use thin connector lines through the center gutter and compact directional copy buttons. Include a slim right-side overview rail with three markers. Semantic red/green appears only inside changed data rows and small result badges; every difference also has +, −, or Δ non-color notation.
Footer text: “Ready”, “3 differences”, badges “2 Added”, “1 Deleted”, “0 Conflicts”, then “JSON”, “UTF-8”, “LF”, “1:1”.
Style/medium: realistic shippable native macOS SwiftUI product UI, precise and dense, flat dark surfaces.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a, #191a1b; hairlines #23252a; primary ink #f7f8f8; muted ink #8a8f98; single brand lavender #5e6ad2 used only for selection, focus, and primary actions. Semantic diff red/green only within data results.
Typography: crisp SF Pro / system sans; SF Mono for paths and code; measured compact hierarchy; all visible labels readable.
Constraints: match Image 1’s overall Riffa geometry and component language; practical macOS layout; 8px control corners and 12px panels; no gradients, no glass, no blur, no translucency, no drop shadows, no glow, no atmospheric lighting, no decorative color, no oversized typography, no rounded pill CTAs, no stock imagery, no watermark, no extra logos, no floating detached cards, no empty state. Do not place the DESIGN.md component specimen sheet beneath the app; output only one complete application window filling the canvas.
```
