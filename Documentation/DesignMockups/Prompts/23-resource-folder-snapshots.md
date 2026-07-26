# 23 Resource Folder Snapshots

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Resource Tools / Folder Snapshots tab
Input images: Image 1 is the Riffa visual-system reference only, not an edit target. Reuse its near-black palette, flat surface hierarchy, SF typography, hairlines, compact controls, and sparse lavender accent while creating this new page.
Primary request: Design the loaded, data-rich result state of Riffa's Folder Snapshots resource tool.
Scene/backdrop: one complete 1536×1024 landscape native macOS app window with title bar and traffic lights, no external scene.
Composition/framing: top product header with small Riffa mark, title “Resource Tools”, subtitle “Snapshots, safe archives, read-only WebDAV, and operation history”. To the right or directly below, a compact segmented tab strip with “Folder Snapshots” selected and three unselected tabs “Archive Browser”, “WebDAV”, “Operations”, each with an icon. Under it, one dense control bar: lavender primary “Create Snapshot…”, secondary “Snapshot vs Folder…”, “Two Snapshots…”, menu “Differences”, search field “Filter paths”, and “Export JSON…”. Main content is a full-height native table with columns “Status”, “Relative Path”, “Left Size”, “Right Size”, “Digest”, “Issues”. Populate realistic rows such as “Sources/App/CompareEngine.swift”, “Sources/App/Theme.swift”, “Resources/AppIcon.png”, “Tests/FolderSnapshotTests.swift”, and “README.md”. Show explicit icon-plus-text statuses “Changed”, “Same”, “Left only”, “Right only”, and “Type mismatch”; monospaced paths and short digest transitions. Bottom status bar shows source description “snapshot-2026-07-25.riffasnapshot ↔ /Users/alex/projects/Riffa”, badges “8 shown” and “5 differences”, plus “Comparison complete”.
Style/medium: shippable native SwiftUI macOS interface, realistic crisp product screenshot, highly practical dense table layout, SF Pro and SF Mono, not concept art.
Color palette: #010102 canvas; #0f1011/#141516/#18191a surfaces; #f7f8f8 text; #8a8f98 secondary text; #23252a hairlines; #5e6ad2 only for active tab, focus, and primary action. Semantic red/amber/green may appear only beside explicit status icons and labels.
Text (verbatim where visible): “Riffa”, “Resource Tools”, “Snapshots, safe archives, read-only WebDAV, and operation history”, “Folder Snapshots”, “Archive Browser”, “WebDAV”, “Operations”, “Create Snapshot…”, “Snapshot vs Folder…”, “Two Snapshots…”, “Differences”, “Filter paths”, “Export JSON…”, “Status”, “Relative Path”, “Left Size”, “Right Size”, “Digest”, “Issues”, “Changed”, “Same”, “Left only”, “Right only”, “Type mismatch”, “8 shown”, “5 differences”, “Comparison complete”.
Constraints: exact flat dark system from reference; table dominates; clear sortable-column rhythm; active tab unmistakable; statuses use symbol plus words; 1 px dividers; practical 36–44 px controls; readable data; one coherent window.
Avoid: gradients, blur, glass, transparency, shadows, glow, card-grid dashboard, charts, decorative imagery, oversized text, pill CTA, decorative rainbow colors, browser chrome, watermark, illegible filler text.
```
