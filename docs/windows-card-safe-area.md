# Expanded card layout

Expanded Rhine cards now fit between the top toolbar and the active bottom
controls. Showing the timeline reserves its complete 234 DIP host plus spacing;
hiding it restores the larger card size above the date dock. The screenshot,
footer, actions and decorative front copy share the same projected card plane.
Top search, application filter, starred memories, Ask Recall, usage, settings,
close and menu controls stay available while a card is open.

Window resizing and timeline visibility changes recalculate both card size and
footer raster scale. A compact icon footer is used when the available height
cannot accommodate full labels; accessible names and tooltips remain. Initial
expansion before XAML measurement no longer derives typography from a near-zero
projection scale.

## Focused verification

- Release Windows publish passed; 97 targeted geometry, motion and archive
  checks passed, including complete-card bounds at four viewport sizes.
- Native synthetic-library screenshots reviewed at 1280 × 800, 960 × 640 and
  800 × 600, with timeline visible and hidden, light and dark appearance, and
  landscape/portrait screenshot content.
- At 1280 × 800 with timeline visible, the toolbar ends at y=89, the complete
  card spans approximately y=113–542, and the timeline begins at y=566. The
  previous card extended to y=735 and overlapped that timeline.
- Native menu opening while the card is expanded and native Collapse clicking
  were verified. Collapsed cards release their front copy and action hit plane;
  hiding Recall disconnects its native backdrop.

This is focused validation of the requested layout change, not a full media,
recording or capture regression run. The fixture contains generated data only.
The installer is delivered without changing the running installation.
