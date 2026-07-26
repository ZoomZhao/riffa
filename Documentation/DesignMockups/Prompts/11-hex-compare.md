# 11 — Hex Compare

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop application screen, Hex Compare main populated result state
Input images: Image 1 is a style reference only; preserve its Riffa product language, sidebar proportions, shared comparison chrome, density, near-black surface ladder, hairline borders, spacing rhythm, and compact native macOS control treatment. Generate a new Hex Compare page rather than editing Image 1.
Primary request: Design the Riffa “Hex Compare” page as a shippable 1536×1024 landscape macOS UI. Show one complete app window with macOS traffic lights and title “Riffa”, persistent left sidebar, shared page header, compact control toolbar, two resource path cards, synchronized binary hex panes, a narrow center difference/action gutter, overview rail, and bottom status bar. This must be a populated comparison result, not an empty state.
Navigation: sidebar brand “Riffa”; sections “COMPARE” and “MERGE & SYNC”; rows including “Folder Compare”, “Text Compare”, “Text Patch”, selected “Hex Compare”, “Image Compare”, “PDF Compare”, “Metadata Compare”, “Table Compare”, then “Folder Merge”, “Folder Sync”, “Text Merge”. Selected Hex Compare row uses a restrained lavender surface highlight with a monochrome number-square icon.
Header: title “Hex Compare”; subtitle “Streamed same-offset binary comparison”; actions “Save Session”, “Compare Options”, previous and next difference icon buttons, and search field containing “89 50 4E 47”.
Control toolbar: “Bytes per row 16”, “Group 4”, “Offset Hex”, checked “Show ASCII”, checked “Highlight Differences”, “Go to 0x00000020”. Use compact segmented controls and checkboxes.
Paths: left `/Users/alex/builds/riffa-1.4/Riffa.bin`; right `/Users/alex/builds/riffa-1.5/Riffa.bin`, each in a surface-2 path card with a monochrome binary document icon and ellipsis accessory.
Data content: two aligned hex editors. Each row begins with readable offsets `00000000`, `00000010`, `00000020`, `00000030`, `00000040`, `00000050`, `00000060`, `00000070`, followed by sixteen hex byte pairs grouped in fours, then an ASCII preview column. Populate plausible executable/binary bytes such as `CF FA ED FE 0C 00 00 01`, `89 50 4E 47 0D 0A 1A 0A`, `52 49 46 46 41 00 01 00`. Show exactly four differing byte positions across rows 00000020, 00000030, and 00000060. Left differing byte cells use a restrained muted red fill plus visible `−` badge; right cells use restrained muted green fill plus visible `+` badge; one changed pair uses a compact `Δ` marker in the center gutter. All unchanged bytes stay neutral. Include thin alignment connectors and small directional copy buttons between panes. Overview rail shows four small difference markers with glyphs, not color alone.
Pane headings: “LEFT · 8.4 MB” and “RIGHT · 8.4 MB” in neutral ink, with “Offset”, “Hex bytes”, and “ASCII” column labels. Never use blue/orange side identity colors.
Footer text: green check icon plus “Ready”; “4 byte differences”; badges “2 Replaced”, “1 Left only”, “1 Right only”; then “16 bytes/row”, “HEX”, “Offset 0x00000020”, “100%”. Semantic color appears only in changed byte cells and result badges, and every colored state has +, −, Δ, icon, or text.
Style/medium: realistic shippable native macOS SwiftUI product UI, precise dense binary editor, flat dark surfaces.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a, #191a1b; hairlines #23252a; ink #f7f8f8; muted ink #8a8f98; one brand lavender #5e6ad2 used only for selection, focus, and primary action. Semantic diff red/green only in data results.
Typography: crisp SF Pro / system sans; SF Mono for paths, offsets, hex bytes, and ASCII; readable compact labels.
Constraints: match Image 1’s Riffa geometry and component language; keep byte columns aligned and technically plausible; practical macOS layout; 8px control corners and 12px panels; no gradients, no glass, no blur, no translucency, no drop shadows, no glow, no decorative color, no oversized typography, no pill CTAs, no stock imagery, no watermark, no extra logos, no floating detached cards, no empty state. Do not include a design-system specimen sheet below the window; output only one complete application window filling the canvas.
```
