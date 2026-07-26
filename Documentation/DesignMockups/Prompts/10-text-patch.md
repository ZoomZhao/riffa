# 10 — Text Patch

Mode: built-in `image_gen`

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa Text Patch page, high-fidelity native macOS implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; preserve its sidebar, solid dark surfaces, compact chrome, typography, controls, and brand mark.
Primary request: design a populated unified-diff review and safe-apply workspace. Persistent sidebar. Header titled Text Patch with patch file selector, target root selector, Save As, and primary Apply to Target action. A compact validation strip states Parsed successfully and 2 files, 5 hunks. Main workspace uses three practical panes: left list of patch file records with Added/Modified/Deleted status and apply checkboxes; middle list of hunks with old/new line ranges and Valid/Offset/Rejected labels; right large unified preview editor with line numbers, context, additions, deletions, and explicit +/− glyph gutters. Selected hunk shows an inline reason and target path. Footer shows dry-run status, backup required, selected hunks, UTF-8, LF.
Style/medium: shippable realistic native macOS product UI, dense patch review tool, not concept art.
Composition/framing: straight-on 16:10 desktop screenshot; preview takes at least half the content width; no floating cards.
Color palette: Image 1 and DESIGN.md. Lavender for selected row, focus, Apply to Target. Restrained semantic diff colors only in patch lines and status icons; all meanings include labels and +/− shapes.
Typography: SF Pro Text in chrome, SF Mono for paths, line ranges, patch content.
Text (verbatim): "Text Patch", "Review before applying", "Patch file", "Target root", "Parsed successfully", "Files", "Hunks", "Modified", "Added", "Deleted", "Valid", "Offset", "Rejected", "Unified Preview", "Dry run", "Backup required", "Apply to Target", "Save As".
Constraints: destructive action clearly separated and always visible; 44px resource controls; 1px hairlines; dense readable code; rejected hunks cannot be selected for apply; status not color-only.
Avoid: gradients, glow, shadows, glass, decorative side colors, oversized banners, floating panels, illegible fake patch text, watermark.
```
