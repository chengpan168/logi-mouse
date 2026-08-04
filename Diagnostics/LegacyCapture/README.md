# Legacy Capture Tools

This folder preserves the data-collection implementation that was removed from
the `logi-mouse` product target.

It contains the former JSONL event schema/logger, capture configuration and CLI
arguments, capture coordinator, long test document, capture-oriented window,
offline analyzer, and their tests. The historical JSONL/CSV samples remain in
the repository-level `captures/` directory; generated curve SVGs remain under
`docs/`.

`Package.swift` intentionally does not include this directory. The product app
therefore does not compile or ship any capture code and never writes capture
files. If event-level diagnostics are needed again, restore these files as a
separate executable target and adapt its HID/CGEvent adapters to the current
runtime interfaces instead of adding collection controls back to the main UI.
