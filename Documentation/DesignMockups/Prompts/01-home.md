# 01 — Home

Mode: built-in `image_gen`, followed by one targeted background refinement.

Reference: `Documentation/DesignMockups/00-master-visual-system.png`

```text
Use case: ui-mockup
Asset type: Riffa native macOS Home page, high-fidelity implementation reference
Input images: Image 1 is the approved Riffa master visual-system reference; preserve its palette, compact components, sidebar geometry, typography, hairlines, and original brand mark.
Primary request: design the complete Home page of Riffa, a professional file comparison app. Keep the persistent 220px sidebar with grouped navigation for Compare and Merge & Sync. In the content area show a compact brand introduction, then a responsive 4-column grid of 15 session launch cards at a 1440px desktop width. Each card has a monochrome line icon, title, one-line purpose, subtle hover affordance, and keyboard focus state. Add a restrained footer row with Apple Silicon Native, Swift, and Files stay local.
Style/medium: shippable realistic native macOS product UI, not marketing concept art.
Composition/framing: straight-on 16:10 desktop app screenshot with real macOS title bar; dense but calm hierarchy; content scroll area clearly visible.
Color palette: exactly follow Image 1 and DESIGN.md; lavender only for brand, selected sidebar row, focus, and one primary launch affordance.
Typography: SF Pro Display/Text with compact labels; no oversized hero.
Text (verbatim): "Riffa", "See what changed.", "Start a session", "Compare", "Merge & Sync", "Folder Compare", "Text Compare", "Text Patch", "Hex Compare", "Media Compare", "Image Compare", "PDF Compare", "Office Compare", "Archive Compare", "Metadata Compare", "Version Compare", "Table Compare", "Folder Merge", "Folder Sync", "Text Merge", "Apple Silicon Native", "Swift", "Files stay local".
Constraints: practical 4/8/12/16/24/32 spacing; cards 12px radius with 1px hairline; minimum 40px interactions; every navigation item readable; preserve master style.
Avoid: gradients, glass, blur, shadows, decorative colors, giant cards, excessive whitespace, floating islands, duplicate logos, illegible fake text, watermark.
```

Refinement:

```text
Use case: precise-object-edit
Input images: Image 1 is the Riffa Home page mockup to refine.
Primary request: remove only the subtle background gradients, glows, and vignettes from the entire interface. Replace them with perfectly uniform solid dark surfaces using canvas #010102 and the flat surface ladder #0f1011, #141516, #18191a, #191a1b.
Constraints: keep every layout position, window size, sidebar, brand mark, card grid, typography, labels, icons, selection state, borders, and footer unchanged; preserve crisp 1px hairlines; no new elements; no removed elements.
Avoid: gradients, glow, shadows, blur, glass, texture, watermark.
```
