# 20 — Metadata Compare

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop application screen, Metadata Compare main populated result state
Input images: Image 1 is a style reference only; preserve its Riffa product language, sidebar proportions, shared comparison chrome, density, near-black surface ladder, hairline borders, spacing rhythm, and compact native macOS control treatment. Generate a new Metadata Compare page, do not edit Image 1.
Primary request: Design the Riffa “Metadata Compare” page as a shippable 1536×1024 landscape macOS UI. Show one complete app window with macOS traffic lights and centered title “Riffa”, persistent left sidebar, shared page header, compact filter controls, two resource path cards, two neutral metadata summary panels, a dense grouped comparison table with populated values, and a bottom status bar. This is the main result state with real-looking data.
Navigation: sidebar brand “Riffa”; sections “COMPARE” and “MERGE & SYNC”; rows including “Folder Compare”, “Text Compare”, “Text Patch”, “Hex Compare”, “Image Compare”, “PDF Compare”, selected “Metadata Compare”, “Table Compare”, then “Folder Merge”, “Folder Sync”, “Text Merge”. Selected Metadata Compare uses a restrained lavender surface highlight and monochrome list/inspector icon.
Header: title “Metadata Compare”; subtitle “Stable inode attributes, ACLs, and bounded xattr digests”; actions “Save Session”, “Refresh”, “Compare Options”, and search field containing “permissions”.
Control toolbar: segmented scope “All / Differences / Extended Attributes” with “Differences” selected using neutral lifted surface rather than a bright fill; checked “Show Equal”; checked “Group by Category”; popup “Digest SHA-256”; compact badge “6 differences”.
Paths: left `/Users/alex/projects/riffa/Riffa.app`; right `/Applications/Riffa.app`, each in a surface-2 resource path card with monochrome app-bundle icon and ellipsis accessory. Between them place a neutral swap button.
Summary panels: two compact neutral panels labelled “LEFT” and “RIGHT”, each showing an app icon, “Riffa.app”, “Application bundle”, size around “18.7 MB”, and modified dates “Jul 25, 2026 18:42” versus “Jul 26, 2026 08:17”. Do not assign decorative colors to sides.
Data table: columns “Status”, “Attribute”, “Left Value”, “Right Value”. Group rows with subtle headers “GENERAL”, “POSIX”, “ACCESS CONTROL”, “EXTENDED ATTRIBUTES”. Populate readable rows: Kind = Directory on both with check icon and “Same”; Size = 19,624,960 vs 19,681,280 with Δ “Changed”; Modified = Jul 25 18:42 vs Jul 26 08:17 with Δ; Owner = alex vs root with Δ; Group = staff vs wheel with Δ; Permissions = 0755 rwxr-xr-x vs 0750 rwxr-x--- with Δ; ACL Entries = 0 vs 1 with + “Right only”; com.apple.quarantine = Not present vs `0083;669f…;Safari;` with + “Right only”; com.apple.FinderInfo = identical digest `9d4e…7c10` on both with check “Same”; CodeResources digest = `31ad…09f2` vs `72bc…f801` with Δ “Changed”. Keep values monospaced and truncate long digests cleanly. Rows alternate only through surface levels and hairlines.
Semantic notation: equal rows use a small check icon and restrained success green; changed rows use a small amber-tinted data badge with `Δ`; right-only rows use a green `+`; if a missing value appears, spell “Not present”. No state may rely on color alone. All semantic color is confined to table status glyphs/data rows and the footer result badges.
Footer text: “Comparison complete”, “18 attributes”, badges “12 Same”, “4 Changed”, “2 Right only”; then “SHA-256”, “ACL + xattrs”, “Local”, “100%”.
Style/medium: realistic shippable native macOS SwiftUI product UI, precise dense inspector/table, flat dark surfaces.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a, #191a1b; hairlines #23252a; primary ink #f7f8f8; muted ink #8a8f98; one brand lavender #5e6ad2 used only for selection, focus, and primary actions. Semantic status colors only in data results.
Typography: crisp SF Pro / system sans; SF Mono for paths, permissions, digests, sizes, and metadata values; clear compact hierarchy.
Constraints: match Image 1’s Riffa geometry and component language; practical macOS layout; 8px control corners and 12px panels; no gradients, no glass, no blur, no translucency, no drop shadows, no glow, no decorative side colors, no oversized typography, no pill CTAs, no stock imagery, no watermark, no extra logos, no floating detached cards, no empty state. Do not include a design-system specimen sheet beneath the app; output only one complete application window filling the canvas.
```
