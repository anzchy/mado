# Mado — Quiet Image Canvas primitives

Binding visual guide: `design/DESIGN.md` (relative to the project root). This system serves the accepted C layout for a native macOS local image viewer; browser prototypes are design aids, not native implementation.

Use cool neutral surfaces, one blue accent, flat navigation rows, 12/13/14/16px system typography, 4/6/10px radii, fine dividers and one restrained popover shadow. Images are content, not decorative cards. Grid mode has a compact native title strip and bottom tools. Viewer mode has no application top toolbar; controls appear on demand. Filmstrip integrates paging instead of duplicating it. Keep keyboard focus distinct from selection, and remove hidden tools from interaction and accessibility trees.

Load the compiled bundle and compose IconButton, Keycap and NavRow. Theme classes live on HTML. Use the tokens in tokens/globals.css, light.css and dark.css; do not invent per-screen colors. Actual hit targets, focus handling, contrast and screen-reader behavior require implementation checks; a visual artifact does not certify accessibility.

The palette and primitive token values originated in mdpro commit cee9af46f390b82f3df656552fe7e46da8870ddd. That is provenance only. Markdown editor layouts, Tauri assumptions, upstream ADRs and contrast exceptions do not apply. Some unused token names remain for compatibility with existing exports; they do not introduce editor features. Original visual source and cleanup are documented in design/IMPORT.md.

## Native implementation specifications

Native work must first read the source documents below (paths relative to the project root). Consumed `_ds/` runtime copies contain the Web bundle and visual guide; native specifications remain in the source system.

- `design/picsee-ui-system/native/README.md`: entry point and scope.
- `design/picsee-ui-system/native/TOKEN_MAPPING.md` and `TOKEN_REGISTRY.json`: semantic role whitelist, theme expressions, unit conversion and source hashes.
- `design/picsee-ui-system/native/COMPONENT_CONTRACTS.md`: proposed native component inputs, states, responsibility and acceptance.
- `design/picsee-ui-system/native/NATIVE_MAPPING.md`: SwiftUI/AppKit ownership, appearance/focus/backing conversion and P0-08 handoff.

Web prototypes continue to use the compiled React primitives. Native implementation consumes these contracts and native resource adapters, not the React bundle. MadoDesignKit is a logical grouping inside existing UI targets, not another production target. UI primitives do not own decoder/cache/file permissions, selection reducers or hide timers. Native APIs and accessibility behavior require SDK compilation and Mac verification before being claimed complete.
