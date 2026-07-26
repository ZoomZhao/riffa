# 06 — Folder Merge

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa Folder Merge page, high-fidelity native macOS implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; preserve its sidebar, compact chrome, surfaces, typography, controls, and brand mark.
Primary request: design a populated three-way Folder Merge workflow. Persistent sidebar; header titled Folder Merge with Save Session and a clearly visible primary Create Output action. A three-column path bar for Left, Base, and Right folders plus an Output folder selector. Below, a filter/control row for All, Changes, Conflicts and Resolve All. Main area: dense hierarchical conflict table with Path, Left, Base, Right, Resolution, and Status columns. Selected conflict opens a compact inspector on the right showing three file summaries and explicit resolution buttons Use Left, Use Base, Use Right, Omit. Include several resolved rows and two unresolved conflicts. Footer shows resolved/unresolved counts and backup requirement.
Style/medium: shippable realistic native macOS product UI, technical and deliberate, not concept art.
Composition/framing: straight-on 16:10 desktop screenshot; table dominates, inspector is about 320px wide, no floating cards.
Color palette: exactly Image 1 and DESIGN.md. Lavender for selection, focus, and Create Output. Semantic warning/red/green only for merge state, always paired with icons and text.
Typography: SF Pro Text, SF Mono for paths, sizes, IDs.
Text (verbatim): "Folder Merge", "Three-way folder reconciliation", "Left", "Base", "Right", "Output", "Conflicts", "Resolve All", "Create Output", "Path", "Resolution", "Unresolved", "Resolved", "Use Left", "Use Base", "Use Right", "Omit", "Backup required".
Constraints: primary Create Output never clipped; 44px path controls; 1px hairlines; compact explicit decision controls; no side identified only by color; keyboard focus visible.
Avoid: gradients, glow, shadows, glass, decorative blue/orange/pink side panels, oversized cards, floating windows, illegible text, watermark.
```
