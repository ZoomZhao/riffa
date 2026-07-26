# 05 — Folder Compare

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa Folder Compare page, high-fidelity native macOS implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; match it exactly for sidebar, header, surfaces, typography, controls, and brand mark.
Primary request: design the populated main result state for Folder Compare. Persistent 220px navigation sidebar; compact title header with Save Session, Refresh, File Actions; second control row with path filter, Show status picker, Rules button, and Compare Options menu; dual folder path buttons with swap. Main workspace is a dense hierarchical file tree table with disclosure arrows, checkboxes, Name, Status, Left Size/Modified and Right Size/Modified columns. Show rows for identical, changed, left-only, right-only, moved, and type mismatch. Include a compact selection/action footer with counts and keyboard hints.
Style/medium: shippable realistic native macOS product UI, technical and dense, not concept art.
Composition/framing: straight-on 16:10 desktop screenshot at 1180–1440 width; table is the protagonist and uses the full remaining height.
Color palette: Image 1 and DESIGN.md surface ladder; lavender only for selection/focus/primary action. Diff semantics may use restrained red/green/amber only inside table cells and must include icons and explicit labels.
Typography: SF Pro Text; file paths, sizes, times in SF Mono.
Text (verbatim): "Folder Compare", "Stable recursive path matching", "Filter paths", "Show", "Rules On", "Compare Options", "File Actions", "Name", "Status", "Left", "Right", "Changed", "Left only", "Right only", "Moved", "Type mismatch", "12 differences".
Constraints: practical controls, 40px key actions, 44px path controls, 1px hairlines, truncation for long paths, Compare Options fully visible, status never color-only.
Avoid: gradients, glow, shadows, glass, decorative side colors, oversized cards, floating panels, illegible text, watermark.
```
