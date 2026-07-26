# 03 Workspace

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Workspace window
Input images: Image 1 is the visual-system reference only, not an edit target. Preserve its Riffa visual language, surface ladder, hairlines, typography, compact controls, and sparse lavender accent while composing a new Workspace screen.
Primary request: Design the loaded main state of a Riffa Workspace window that restores several saved comparison sessions as ordered tabs.
Scene/backdrop: one complete 1536×1024 landscape native macOS app window with dark title bar and traffic-light controls; no external environment.
Composition/framing: title bar centered text “Release Workspace”. Directly under it, a compact horizontal workspace tab strip on surface-1 with four tabs: selected “Release Review” with text-document icon, then “Folder Audit”, “Docs Update”, and “Mirror Deploy”. Each tab has an icon and concise label, with only the selected tab using a subtle lavender selection surface. Below the tab strip mount one full active Text Compare session: compact header with title “Text Compare”, subtitle “Two-way, line aligned”, actions “Save Session”, search, previous/next difference, bookmarks, and more; a path bar with two monospaced local file paths and swap control; a dense two-pane diff of JSON with line numbers, explicit red deletion rows, green insertion rows, amber modified rows, center change glyphs, difference overview rail, and a bottom statistics/status bar. Include a compact workspace-management icon in the tab strip but no sidebar.
Style/medium: shippable native SwiftUI macOS interface, realistic crisp product screenshot, SF Pro and SF Mono, practical dense layout, not concept art.
Color palette: #010102 canvas; #0f1011/#141516/#18191a surfaces; #f7f8f8 primary text; #8a8f98 secondary text; #23252a hairlines; #5e6ad2 lavender only for active tab, focus, and primary action. Red/green/amber are allowed only for semantic diff states and must be paired with +, −, or pencil/equal symbols.
Text (verbatim where visible): “Riffa”, “Release Workspace”, “Release Review”, “Folder Audit”, “Docs Update”, “Mirror Deploy”, “Text Compare”, “Two-way, line aligned”, “Save Session”, “LEFT”, “RIGHT”, “config.json”, “config.remote.json”, “3 differences”, “1 modified”, “1 deleted”, “1 inserted”, “Ready”.
Constraints: make the workspace tab strip unmistakably distinct from the session toolbar; realistic SwiftUI sizing; all paths in monospace; clear active tab; accessible state via icon plus label, not color alone; exact flat near-black design; one coherent window.
Avoid: sidebar, gradients, glass, transparency, blur, shadows, glow, decorative art, oversized tabs, floating cards, pill CTAs, multiple decorative colors, browser chrome, watermark, illegible filler text.
```
