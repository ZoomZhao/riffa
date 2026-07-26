# 09 — Text Merge

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa Text Merge page, high-fidelity native macOS implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; match its sidebar, solid dark surfaces, compact chrome, typography, controls, and brand mark.
Primary request: design a populated three-way Text Merge conflict-resolution workspace. Persistent sidebar. Header titled Text Merge with Save Session, Undo, Redo, and primary Save Result. Three compact source path buttons labeled Left, Base, Right. Main area has a narrow conflict navigator on the left listing numbered conflicts with explicit Unresolved or Resolved badges; the center shows three aligned read-only code panes Left/Base/Right; the lower half or right pane contains the editable Merged Result. The selected conflict has clear buttons Use Left, Use Base, Use Right, Keep Both, Mark Resolved. Show inline line numbers, connecting alignment guides, and two resolved plus one unresolved conflict. Footer shows 3 conflicts, 2 resolved, 1 unresolved, UTF-8, LF, modified state.
Style/medium: shippable realistic native macOS product UI, dense professional merge editor, not concept art.
Composition/framing: straight-on 16:10 desktop screenshot; code and conflict resolution are the protagonist; no floating islands.
Color palette: Image 1 and DESIGN.md. Lavender for selected conflict, focus, Save Result. Restrained semantic red/green/amber only in changed code and status, always paired with symbols/text. Left/Base/Right identities remain neutral.
Typography: SF Pro Text for chrome; SF Mono for code, line numbers, paths.
Text (verbatim): "Text Merge", "Three-way conflict resolution", "Left", "Base", "Right", "Merged Result", "Conflicts", "Unresolved", "Resolved", "Use Left", "Use Base", "Use Right", "Keep Both", "Mark Resolved", "Save Result", "Modified".
Constraints: non-color status, visible keyboard focus, readable 12–13pt code, 1px pane separators, primary Save Result always visible, editor fills remaining height.
Avoid: gradients, glow, shadows, glass, decorative side colors, oversized cards, floating panels, illegible fake code, watermark.
```
