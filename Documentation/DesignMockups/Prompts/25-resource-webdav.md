# 25 Resource WebDAV

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Resource Tools / WebDAV tab
Input images: Image 1 is a visual-style reference only, not an edit target. Use its Riffa colors, typography, hairlines, compact controls, and sparse lavender accent. Do NOT copy its left application sidebar.
Primary request: Create the connected, data-rich WebDAV tab inside the dedicated Resource Tools window.
Scene/backdrop: one complete 1536×1024 landscape native macOS window with title bar and traffic-light controls; the Resource Tools content spans the FULL WIDTH below the title bar.
Composition/framing: CRITICAL — NO LEFT SIDEBAR, NO FAVORITES, NO RECENT CONNECTIONS, NO SAVED SESSIONS. The only navigation is a full-width compact tab strip near the top: “Folder Snapshots”, “Archive Browser”, selected “WebDAV”, “Operations”. Above it show title “Resource Tools” and subtitle “Snapshots, safe archives, read-only WebDAV, and operation history”. Connection surface spans full width. First row: URL “https://dav.example.com/team/”, Authentication “Basic”, “Reconnect”, “Disconnect”. Second row: “Username” value “alex”, masked password, checked “Remember in Keychain”, “Save”, “Check”, shield-plus-text “Saved”, “Forget”. Browser toolbar: Up, “Open Collection”, refresh, breadcrumb “/projects/riffa”, “Filter paths”, “Compare Text”, “Export Selected…”. Marked-files strip: “LEFT  config.json”, “RIGHT  config.remote.json”, lavender primary “Compare”. Main full-width area uses a 55/45 split: left table with “Kind”, “Name”, “Size”, “Modified” and 9 entries, selected “config.remote.json”; right pane shows filename, remote path, and readable monospaced JSON preview. Bottom bar: server URL, current path, “9 of 9 entries”, shield-plus-text “Read-only”.
Style/medium: shippable native SwiftUI macOS product interface, crisp realistic screenshot, dense practical layout, SF Pro / SF Mono, not concept art.
Color palette: canvas #010102; surfaces #0f1011, #141516, #18191a; text #f7f8f8/#d0d6e0/#8a8f98; hairlines #23252a; lavender #5e6ad2 only for selected tab, selected row, focus, checkbox, and Compare. Muted secure lavender-gray for shield status.
Text (verbatim where visible): “Riffa”, “Resource Tools”, “Snapshots, safe archives, read-only WebDAV, and operation history”, “Folder Snapshots”, “Archive Browser”, “WebDAV”, “Operations”, “https://dav.example.com/team/”, “Authentication”, “Basic”, “Reconnect”, “Disconnect”, “Username”, “alex”, “Remember in Keychain”, “Save”, “Check”, “Saved”, “Forget”, “Open Collection”, “/projects/riffa”, “Filter paths”, “Compare Text”, “Export Selected…”, “LEFT”, “config.json”, “RIGHT”, “config.remote.json”, “Compare”, “Kind”, “Name”, “Size”, “Modified”, “9 of 9 entries”, “Read-only”.
Constraints: no sidebar under any circumstance; never expose the password; read-only uses shield plus text; connection controls, browser controls, and marked comparison strip are clearly separated by 1 px hairlines; table and preview dominate; one coherent full-width window.
Avoid: any left navigation rail or sidebar, recent/favorites lists, gradients, blur, glass, translucency, shadows, glow, network illustration, dashboard cards, giant labels, pill CTA, decorative bright colors, exposed secrets, browser chrome, watermark, illegible filler text.
```
