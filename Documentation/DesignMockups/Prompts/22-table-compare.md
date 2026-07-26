# 22 — Table Compare

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop application screen, Table Compare main populated result state
Input images: Image 1 is a style reference only; preserve its Riffa product language, sidebar proportions, shared comparison chrome, density, near-black surface ladder, hairline borders, spacing rhythm, and compact native macOS control treatment. Generate a new Table Compare page, do not edit Image 1.
Primary request: Design the Riffa “Table Compare” page as a shippable 1536×1024 landscape macOS UI. Show one complete app window with macOS traffic lights and centered title “Riffa”, persistent left sidebar, shared page header, comparison control toolbar, two resource path cards, a populated row-alignment results table, a compact selected-row detail panel, and a bottom status bar. This is the main result state after comparing two CSV files.
Navigation: sidebar brand “Riffa”; sections “COMPARE” and “MERGE & SYNC”; rows including “Folder Compare”, “Text Compare”, “Text Patch”, “Hex Compare”, “Image Compare”, “PDF Compare”, “Metadata Compare”, selected “Table Compare”, then “Folder Merge”, “Folder Sync”, “Text Merge”. Selected Table Compare uses a restrained lavender surface highlight with monochrome table-grid icon.
Header: title “Table Compare”; subtitle “Delimited data with composite-key row alignment”; actions “Save Session”, “Export Report”, “Compare Options”, previous/next difference icon buttons, and search field containing “enterprise”.
Control toolbar: “Delimiter Comma”, “Header Row 1”, “Key Columns id”, “Match Exact”, checked “Ignore Row Order”, unchecked “Ignore Empty Columns”, segmented “All / Differences / Conflicts” with “Differences” selected using neutral lifted surface. Include compact badge “4 differences”.
Paths: left `/Users/alex/data/customers-2025.csv`; right `/Users/alex/data/customers-2026.csv`, each in a surface-2 resource card with monochrome table icon and ellipsis accessory, separated by a neutral swap button.
Main table: dense practical columns “Status”, “Key”, “name · Left”, “name · Right”, “plan · Left”, “plan · Right”, “seats · Left”, “seats · Right”, “region · Left”, “region · Right”. Use readable SF Mono values where appropriate. Populate rows:
- check “Same”, key `C-1001`, Acme Labs / Acme Labs, Pro / Pro, 24 / 24, US-East / US-East.
- Δ “Modified”, key `C-1002`, Northstar / Northstar, Team / Enterprise, 48 / 75, EU-West / EU-West.
- − “Left only”, key `C-1003`, Atlas Works / Not present, Pro / Not present, 16 / Not present, AP-South / Not present.
- + “Right only”, key `C-1004`, Not present / Meridian AI, Not present / Pro, Not present / 12, Not present / US-West.
- Δ “Modified”, key `C-1005`, Pine & Co / Pine & Co, Basic / Pro, 8 / 10, US-East / US-East.
- warning triangle “Duplicate key”, key `C-1008`, two matched candidates, Enterprise, 120, EU-Central.
- check “Same”, key `C-1010`, Harbor Systems on both, Team on both, 32 on both, US-West on both.
Confine muted red/green/amber semantic fills to the affected table cells and compact status badges. Every state also includes check, Δ, −, +, warning icon, and explicit text, never color alone. Lavender is not used for table differences; it may only mark selected navigation and keyboard focus.
Selected-row detail panel below table: neutral surface labelled “SELECTED ROW · C-1002 · MODIFIED”; show three field comparison chips: `plan  Team → Enterprise`, `seats  48 → 75`, `region  EU-West = EU-West`; actions “Copy Left to Right”, “Copy Right to Left”, “Exclude Row”. Use arrows and equality symbols as non-color indicators.
Footer text: check icon plus “Comparison complete”; “7 rows shown”; badges “2 Modified”, “1 Left only”, “1 Right only”, “1 Duplicate”; then “CSV”, “Key: id”, “UTF-8”, “100%”.
Style/medium: realistic shippable native macOS SwiftUI product UI, precise dense data-grid, flat dark surfaces.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a, #191a1b; hairlines #23252a; primary ink #f7f8f8; muted ink #8a8f98; one brand lavender #5e6ad2 used only for selection, focus, and primary actions. Semantic colors only within affected result cells and badges.
Typography: crisp SF Pro / system sans; SF Mono for paths, keys, counts, and table values; readable compact labels with aligned columns.
Constraints: match Image 1’s Riffa geometry and component language; practical macOS layout; maintain clear table grid and column alignment; 8px control corners and 12px panels; no gradients, no glass, no blur, no translucency, no drop shadows, no glow, no decorative colors, no oversized typography, no pill CTAs, no stock imagery, no watermark, no extra logos, no floating detached cards, no empty state. Do not include a design-system specimen sheet beneath the app; output only one complete application window filling the canvas.
```
