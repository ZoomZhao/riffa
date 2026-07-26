# Riffa ImageGen UI reference set

This directory contains the implementation references for every primary Riffa
page. Each image was generated with the built-in `image_gen` tool, one call per
page or mode, using `00-master-visual-system.png` as the shared style reference.
The complete verbatim prompt for every image lives in `Prompts/`.

The images define hierarchy, density, component language, and responsive
priorities. Example paths, counts, dates, and document content are illustrative;
the SwiftUI implementation must always render the real model data.

## Global and management pages

| Reference | Page | Prompt |
|---|---|---|
| [00-master-visual-system.png](00-master-visual-system.png) | Shared visual system | [Prompt](Prompts/00-master-visual-system.md) |
| [01-home.png](01-home.png) | Home and primary sidebar | [Prompt](Prompts/01-home.md) |
| [02-session-library.png](02-session-library.png) | Session Library | [Prompt](Prompts/02-session-library.md) |
| [03-workspace.png](03-workspace.png) | Workspace window | [Prompt](Prompts/03-workspace.md) |
| [04-settings.png](04-settings.png) | Settings | [Prompt](Prompts/04-settings.md) |

## Compare, merge, and synchronize

| Reference | Page | Prompt |
|---|---|---|
| [05-folder-compare.png](05-folder-compare.png) | Folder Compare | [Prompt](Prompts/05-folder-compare.md) |
| [06-folder-merge.png](06-folder-merge.png) | Folder Merge | [Prompt](Prompts/06-folder-merge.md) |
| [07-folder-sync.png](07-folder-sync.png) | Folder Sync | [Prompt](Prompts/07-folder-sync.md) |
| [08-text-compare.png](08-text-compare.png) | Text Compare | [Prompt](Prompts/08-text-compare.md) |
| [09-text-merge.png](09-text-merge.png) | Text Merge | [Prompt](Prompts/09-text-merge.md) |
| [10-text-patch.png](10-text-patch.png) | Text Patch | [Prompt](Prompts/10-text-patch.md) |
| [11-hex-compare.png](11-hex-compare.png) | Hex Compare | [Prompt](Prompts/11-hex-compare.md) |
| [12-media-compare.png](12-media-compare.png) | Media Compare | [Prompt](Prompts/12-media-compare.md) |
| [13-image-compare.png](13-image-compare.png) | Image Compare | [Prompt](Prompts/13-image-compare.md) |
| [14-pdf-pages.png](14-pdf-pages.png) | PDF Compare — Pages | [Prompt](Prompts/14-pdf-pages.md) |
| [15-pdf-text.png](15-pdf-text.png) | PDF Compare — Text | [Prompt](Prompts/15-pdf-text.md) |
| [16-pdf-visual.png](16-pdf-visual.png) | PDF Compare — Visual | [Prompt](Prompts/16-pdf-visual.md) |
| [17-pdf-metadata.png](17-pdf-metadata.png) | PDF Compare — Metadata | [Prompt](Prompts/17-pdf-metadata.md) |
| [18-office-compare.png](18-office-compare.png) | Office Compare | [Prompt](Prompts/18-office-compare.md) |
| [19-archive-compare.png](19-archive-compare.png) | Archive Compare | [Prompt](Prompts/19-archive-compare.md) |
| [20-metadata-compare.png](20-metadata-compare.png) | Metadata Compare | [Prompt](Prompts/20-metadata-compare.md) |
| [21-version-compare.png](21-version-compare.png) | Version Compare | [Prompt](Prompts/21-version-compare.md) |
| [22-table-compare.png](22-table-compare.png) | Table Compare | [Prompt](Prompts/22-table-compare.md) |

## Resource Tools

| Reference | Page | Prompt |
|---|---|---|
| [23-resource-folder-snapshots.png](23-resource-folder-snapshots.png) | Folder Snapshots | [Prompt](Prompts/23-resource-folder-snapshots.md) |
| [24-resource-archive-browser.png](24-resource-archive-browser.png) | Archive Browser | [Prompt](Prompts/24-resource-archive-browser.md) |
| [25-resource-webdav.png](25-resource-webdav.png) | WebDAV | [Prompt](Prompts/25-resource-webdav.md) |
| [26-resource-operations.png](26-resource-operations.png) | Operation History | [Prompt](Prompts/26-resource-operations.md) |

## Implementation rules

- Use the exact `DESIGN.md` palette and surface ladder; generated pixel colors
  are references, not substitutes for design tokens.
- Do not ship bitmap mockups inside the application.
- Use SF Pro and SF Mono through the existing SwiftUI typography tokens.
- Keep lavender for brand, focus, selection, and primary actions.
- Conflicts and differences must include icons, labels, or `+ / − / Δ`
  notation in addition to semantic color.
- At minimum window sizes, save/apply/export/cancel actions remain reachable.
- No gradients, glass materials, blur, drop shadows, or decorative side colors.
