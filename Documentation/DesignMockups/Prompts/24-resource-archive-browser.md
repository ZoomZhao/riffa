# 24 Resource Archive Browser

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Resource Tools / Archive Browser tab
Input images: Image 1 is the Riffa visual-system reference only, not an edit target. Match its near-black surfaces, sparse lavender accent, SF typography, monospaced data, compact controls, and hairline structure while making a new screen.
Primary request: Design the loaded main state of Riffa's read-only Archive Browser with a selected text member preview.
Scene/backdrop: one complete 1536×1024 landscape native macOS app window with title bar and traffic-light controls, no outside environment.
Composition/framing: shared Resource Tools header with title and subtitle, then four tabs: “Folder Snapshots”, selected “Archive Browser”, “WebDAV”, “Operations”. Control bar has lavender primary “Open Archive…”, search field “Filter archive paths”, and secondary “Export Selected…”. Main area is a horizontal split view: left side about 64% width is a dense native table with columns “Kind”, “Path”, “Size”, “Method”, “Modified”; show validated ZIP members including folders and files under “Sources/”, “Resources/”, “Tests/”, “README.md”, and “LICENSE”. Select “README.md” with a subtle lavender row selection. Right preview pane has header “README.md”, subline “file · 3.2 KB”, and a crisp monospaced text preview with headings “Riffa”, “Native comparison for macOS”, “Build”, and a few command lines. Bottom status bar shows monospaced source path “/Users/alex/Downloads/Riffa-0.1-source.zip”, a secure badge “ZIP”, badge “12 of 12 entries”, and status “Opened 12 validated entries.”
Style/medium: shippable native SwiftUI macOS product interface, realistic crisp product screenshot, dense practical browser layout, SF Pro / SF Mono, not concept art.
Color palette: #010102 canvas; #0f1011/#141516/#18191a surfaces; #f7f8f8 text; #8a8f98 secondary; #23252a hairlines; #5e6ad2 only for selected tab, selected row, focus, and primary action. Secure badge may use muted lavender-gray.
Text (verbatim where visible): “Riffa”, “Resource Tools”, “Snapshots, safe archives, read-only WebDAV, and operation history”, “Folder Snapshots”, “Archive Browser”, “WebDAV”, “Operations”, “Open Archive…”, “Filter archive paths”, “Export Selected…”, “Kind”, “Path”, “Size”, “Method”, “Modified”, “README.md”, “file · 3.2 KB”, “Native comparison for macOS”, “Build”, “ZIP”, “12 of 12 entries”, “Opened 12 validated entries.”
Constraints: clear split-view divider; table dominates left; preview is plain local text, not a code-editor fantasy; archive safety is communicated through icon-plus-text badges; 1 px hairlines; practical row heights; one coherent window.
Avoid: gradients, glass, transparency, blur, drop shadows, glow, decorative archive illustration, card dashboard, huge preview typography, pill CTA, bright decorative colors, browser chrome, watermark, illegible filler text.
```
