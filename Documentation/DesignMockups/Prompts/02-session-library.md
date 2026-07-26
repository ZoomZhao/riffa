# 02 Session Library

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, dedicated Session Library window
Input images: Image 1 is a visual-system reference only, not an edit target. Use its Riffa colors, SF typography, flat surfaces, compact controls, and hairlines. Do NOT copy its global application navigation or Settings footer.
Primary request: Create the loaded, data-rich main state of Riffa's dedicated Session Library window.
Scene/backdrop: one complete 1536×1024 landscape native macOS window. The title bar must read “Session Library” with traffic-light controls. No external scenery.
Composition/framing: two-column NavigationSplitView. CRITICAL — this is not the main comparison sidebar: do not include Folder Compare, Text Compare, Merge & Sync, Settings, Favorites, or Recent Comparisons. Left library sidebar about 330 px wide begins with lavender primary “New Session”, compact overflow and refresh buttons, then search field “Search sessions”. Next show a compact section “WORKSPACE WINDOWS” containing “Release Workspace” and “Docs Audit”. Below show saved sessions grouped under “RELEASES” and “UNGROUPED”, with rows “Release Review”, “Pre-Release QA”, “Config Migration”, “Docs Update”, “Temp Compare”; select “Release Review”. At the very bottom show a quiet truncated monospaced catalog path, not a Settings link. Right detail pane shows a 48 px comparison icon, title “Release Review”, subtitle “Text Compare”, primary “Open”, secondary “Add to Workspace”, overflow. Below, three dense flat bordered sections: “SESSION” with Kind, Group, Created, Updated; “RESOURCES (2)” with local paths “/Users/alex/projects/app/config.json” and “/Users/alex/projects/app/config.remote.json”; “OPTIONS (4)” with “Ignore whitespace”, “Ignore case”, “View”, “Encoding”. Include a quiet icon-plus-text note “Local metadata only”.
Style/medium: shippable native SwiftUI macOS product interface, realistic crisp screenshot, practical dense information management, SF Pro / SF Mono, not concept art.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a; text #f7f8f8/#d0d6e0/#8a8f98; hairlines #23252a; lavender #5e6ad2 only for selected row, focus, Riffa mark, and primary Open/New Session action. Secure note uses muted lavender-gray.
Text (verbatim where visible): “Session Library”, “New Session”, “Search sessions”, “WORKSPACE WINDOWS”, “Release Workspace”, “Docs Audit”, “RELEASES”, “UNGROUPED”, “Release Review”, “Pre-Release QA”, “Config Migration”, “Docs Update”, “Temp Compare”, “Text Compare”, “Open”, “Add to Workspace”, “SESSION”, “Kind”, “Group”, “Created”, “Updated”, “RESOURCES (2)”, “OPTIONS (4)”, “Ignore whitespace”, “Ignore case”, “View”, “Encoding”, “Local metadata only”.
Constraints: dedicated library hierarchy only; clear selected session; monospaced paths; readable row density; 1 px dividers; flat 8–12 px radius panels; state always icon plus label; title bar says Session Library; one coherent window.
Avoid: global app navigation items, Settings link, Favorites, Recent Comparisons, gradients, blur, glass, translucency, drop shadows, glow, decorative illustration, dashboard cards, oversized headings, pill CTA, multiple decorative colors, browser chrome, watermark, illegible filler text.
```
