# 12 — Media Compare

```text
Use case: ui-mockup
Asset type: high-fidelity production-ready macOS desktop app screen for Riffa
Input images: Image 1 is the master visual-system reference only. Preserve its Riffa macOS shell, proportions, density, typography scale, component language, sidebar rhythm, surface hierarchy, and restrained craftsmanship; do not copy its Text Compare page content.
Primary request: design the populated main state of the Riffa “Media Compare” page.
Scene/backdrop: one complete 3:2 macOS application window with native red/yellow/green traffic lights, title “Riffa”, a narrow left navigation sidebar, compact header and toolbar, central comparison table, and bottom status bar.
Style/medium: shippable native SwiftUI/AppKit product UI, precise SF Pro typography with SF Mono only for paths and technical values, realistic controls, crisp 1 px dividers, compact information density.
Composition/framing: match Image 1’s full-window framing. In the sidebar select “Media Compare” with a restrained lavender selected state. The page header reads “Media Compare” with the subtitle “Technical metadata and stream properties”. Show path controls for “/Volumes/Studio/episode-master.m4a” and “/Volumes/Studio/episode-release.m4a”. Toolbar controls: “Save Session”, checked “Ignore Case”, checked “Ignore Whitespace”, “Tolerance 0.001”, checked “Differences”, and “Export Report”. Main table columns: “Status”, “Property”, “Left”, “Right”. Populate rows including Duration “00:42:18.240” vs “00:42:18.198” marked “≠ Changed”; Codec “AAC” vs “AAC” marked “= Same”; Sample Rate “48,000 Hz” vs “48,000 Hz”; Bit Rate “320 kbps” vs “256 kbps” marked changed; Channels “Stereo” vs “Stereo”; File Size “96.8 MB” vs “77.6 MB” marked changed; Encoder “Apple AudioToolbox” vs “ffmpeg” marked changed; Album Art “Present” vs “Present”. Bottom status reads “Ready”, “12 properties”, “4 changed”, “8 same”.
Color palette: exact dark-only DESIGN.md palette—canvas #010102, surfaces #0f1011 #141516 #18191a, ink #f7f8f8, muted #d0d6e0, subtle #8a8f98, hairlines #23252a. Lavender #5e6ad2 is scarce and used only for selection, primary action, and focus. Semantic changed/same states remain subdued and always include explicit icon plus text.
Constraints: every semantic status must be understandable without color; native SF symbols only; all text practical and legible; clear keyboard focus affordance; long paths truncate elegantly; no clipped controls; no proprietary Beyond Compare branding.
Avoid: gradients, glass, blur, translucency, drop shadows, spotlight effects, decorative neon, bright pink or purple side coding, oversized cards, pill-shaped primary buttons, marketing illustration, concept art, watermark, fake logos.
```
