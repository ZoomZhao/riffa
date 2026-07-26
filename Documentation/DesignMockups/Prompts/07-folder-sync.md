# 07 — Folder Sync

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa Folder Sync page, high-fidelity native macOS implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; preserve its sidebar, compact chrome, solid dark surfaces, typography, controls, and brand mark.
Primary request: design a populated synchronization plan for Folder Sync. Persistent sidebar. Header has title/subtitle, Save Session and a primary Apply Plan button that remains visible at minimum width. A separate second row contains Mode picker set to Mirror to Right, Detect moves checkbox, Show unchanged checkbox, and Refresh. Dual folder path bar with swap. Main workspace is a dense plan table with selectable rows and columns Path, Planned Action, Reason, Size, Risk. Show Copy to Right, Delete from Right, Move, No action, and Conflict rows. Include a restrained warning strip above the table stating the plan is read-only until applied, and a compact right-side summary column with counts, backup destination, estimated data, and explicit blocking conflicts. Footer shows actionable items, conflicts, backup required.
Style/medium: shippable realistic native macOS product UI, technical and safe, not concept art.
Composition/framing: straight-on 16:10 desktop screenshot; table uses most vertical space; action summary about 300px wide.
Color palette: match Image 1 and DESIGN.md. Lavender for selection, focus, Apply Plan. Semantic red/green/amber only for plan data and always paired with icons/text.
Typography: SF Pro Text; paths, byte counts, plan IDs in SF Mono.
Text (verbatim): "Folder Sync", "Preview first — writes require backup and confirmation", "Apply Plan", "Mode", "Mirror to Right", "Detect moves", "Show unchanged", "Planned Action", "Copy to Right", "Delete from Right", "Move", "Conflict", "Read-only preview", "Backup required", "3 conflicts block apply".
Constraints: Apply Plan always visible; secondary options live on their own row; destructive actions previewed, not emphasized decoratively; 1px hairlines; statuses not color-only; 44px path targets.
Avoid: gradients, glow, shadows, glass, decorative colors, oversized banners, floating cards, hidden primary action, illegible text, watermark.
```
