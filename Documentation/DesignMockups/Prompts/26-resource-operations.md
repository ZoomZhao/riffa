# 26 Resource Operations

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Resource Tools / Operations tab
Input images: Image 1 is the Riffa visual-system reference only, not an edit target. Reuse its near-black flat surface ladder, hairlines, SF typography, dense data presentation, and sparse lavender accent in a new page.
Primary request: Design the loaded main state of Riffa's operation-journal history with one interrupted folder operation selected and a read-only recovery assessment visible.
Scene/backdrop: one complete 1536×1024 landscape native macOS app window with dark title bar and traffic-light controls, no external scene.
Composition/framing: NO left navigation sidebar. At top use the shared Resource Tools header with title, subtitle, and compact tabs “Folder Snapshots”, “Archive Browser”, “WebDAV”, selected “Operations”. Toolbar below has “Refresh”, menu “All Journals”, search “Filter ID, kind, or root path”, “Reveal Logs”, and “Archive Finished”. Main content is an HSplitView: left table about 55% width with columns “Status”, “Stored”, “Kind”, “Recovery”, “Updated”, “ID”. Populate six realistic records showing icon-plus-text statuses “Completed”, “Rolled back”, “Failed”, and selected “Executing”; storage values “Active log” and “Archived log”; recovery values “Matches completed”, “Matches rolled back”, and selected “Review required”. Right detail pane for selected ID “8F4A12C9” shows heading “Folder Sync”, explicit status badge “Executing”, “Active log”, and a bordered warning: “Non-terminal record — inspect roots and backup before changing files.” Below show section “READ-ONLY RECOVERY ASSESSMENT” with icon-plus-text disposition “Review required” and concise explanation, then dense sections “TIMELINE”, “ROOTS”, and “STEPS (4)”. Steps show numbered rows with statuses “Completed”, “Executing”, and “Pending”, action names and monospaced routes. Bottom status bar shows icon plus “1 operation needs inspection” and “Loaded 6 journals”.
Style/medium: shippable native SwiftUI macOS product interface, realistic crisp screenshot, audit-oriented dense split layout, SF Pro / SF Mono, not concept art.
Color palette: #010102 canvas; #0f1011/#141516/#18191a surfaces; #f7f8f8 text; #8a8f98 muted text; #23252a hairlines; #5e6ad2 only for selected tab, selected table row, focus, and a truly primary action. Semantic red/amber/green only for journal states and always paired with icons and words.
Text (verbatim where visible): “Riffa”, “Resource Tools”, “Folder Snapshots”, “Archive Browser”, “WebDAV”, “Operations”, “Refresh”, “All Journals”, “Filter ID, kind, or root path”, “Reveal Logs”, “Archive Finished”, “Status”, “Stored”, “Kind”, “Recovery”, “Updated”, “ID”, “Completed”, “Rolled back”, “Failed”, “Executing”, “Active log”, “Archived log”, “Review required”, “Folder Sync”, “8F4A12C9”, “Non-terminal record — inspect roots and backup before changing files.”, “READ-ONLY RECOVERY ASSESSMENT”, “TIMELINE”, “ROOTS”, “STEPS (4)”, “Pending”, “1 operation needs inspection”, “Loaded 6 journals”.
Constraints: no automatic-recovery affordance; recovery is clearly read-only; warning is visible but compact; table and evidence detail dominate; statuses never rely on color alone; 1 px dividers; practical row density; no sidebar; one coherent window.
Avoid: gradients, blur, glass, transparency, shadows, glow, dramatic warning illustration, charts, card-grid dashboard, giant status badges, pill CTA, decorative rainbow colors, destructive action as primary, browser chrome, watermark, illegible filler text.
```
