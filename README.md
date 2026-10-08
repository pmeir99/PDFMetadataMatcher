# PDF Metadata Matcher

Native macOS SwiftUI utility for inspecting and comparing PDF metadata.

## Features

- Pick a source and destination PDF
- Inspect and compare metadata side by side
- Show PDF signature status and qpdf structural checks
- Match supported descriptive fields (Title, Subject, Keywords and Author) on unsigned documents into a separate copy
- Do not rewrite digitally signed PDFs or copy provenance, original producer history, document IDs, download history, or dates

## Requirements

macOS 13+, Swift 5.9+, ExifTool, qpdf, Poppler:

```sh
brew install exiftool qpdf poppler
swift run
```

The app uses tools installed in /opt/homebrew/bin or /usr/local/bin. This initial source package has not yet been tested on a Mac.

## Notes

PDF metadata edits performed by ExifTool may be incremental. A matching operation is not a guarantee that prior revisions are unrecoverable. This utility does not certify the authenticity of PDF documents.
