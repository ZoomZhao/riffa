# 04 Settings

Built-in `image_gen` with
`Documentation/DesignMockups/00-master-visual-system.png` as the visual-system
reference.

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop product UI design mockup, Settings page
Input images: Image 1 is the visual-system reference only, not an edit target. Reuse the same flat dark Riffa design system, typography, controls, border treatment, and sparse lavender accent in a new Settings composition.
Primary request: Design Riffa's concise native macOS Settings window focused on accessibility behavior and local privacy.
Scene/backdrop: a single complete native macOS settings window in a 1536×1024 landscape image, dark title bar with traffic-light controls, no device mockup or external scenery.
Composition/framing: centered content column about 860 px wide with generous but practical margins. Header “Settings” and subtitle “Riffa follows your macOS accessibility preferences.” First bordered surface section titled “ACCESSIBILITY” with icon and heading “Focused dark appearance”, supporting explanation, then four compact rows: “Increase Contrast”, “Reduce Transparency”, “Reduce Motion”, “Differentiate Without Color”; each row has a recognizable SF-symbol-like icon, short description, and right-aligned neutral status badge “Follow System”. Second bordered section titled “PRIVACY” with shield icon and heading “Local by default”, explanation “Riffa does not upload compared files.” Include three compact factual rows: “Compared files stay on this Mac”, “Reports are saved only when requested”, and “Remote credentials require explicit Keychain save”, each paired with check/shield icon plus text. Finish with a quiet footer showing app version “Riffa 0.1” and “Apple Silicon”. No editable toggles because these preferences follow macOS.
Style/medium: shippable native SwiftUI macOS interface, crisp realistic product screenshot, SF Pro typography, restrained settings layout, not a marketing page.
Color palette: #010102 canvas; #0f1011 and #141516 panels; #f7f8f8 primary text; #d0d6e0 muted text; #8a8f98 tertiary text; #23252a hairlines; #5e6ad2 only for the small Riffa mark and focus indication. Muted secure lavender-gray may be used for shield icons.
Text (verbatim): “Settings”, “Riffa follows your macOS accessibility preferences.”, “ACCESSIBILITY”, “Focused dark appearance”, “Increase Contrast”, “Reduce Transparency”, “Reduce Motion”, “Differentiate Without Color”, “Follow System”, “PRIVACY”, “Local by default”, “Riffa does not upload compared files.”, “Compared files stay on this Mac”, “Reports are saved only when requested”, “Remote credentials require explicit Keychain save”, “Riffa 0.1”, “Apple Silicon”.
Constraints: readable at macOS desktop scale; row states communicated with icon and text; aligned 1 px hairlines; 8–12 px corners; compact 4/8/12/16/24 spacing; no controls implying Riffa overrides system accessibility settings; one coherent window.
Avoid: gradients, glass, translucency, blur, shadows, glow, decorative graphics, giant headings, colored section fills, bright green decoration, pill CTAs, extra navigation categories, fake browser chrome, watermark, illegible filler text.
```
