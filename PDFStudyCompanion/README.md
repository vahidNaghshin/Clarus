# Clarus

<p align="center"><i>A macOS reading companion for dense PDFs.</i></p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/swift-5.9%2B-orange">
  <img alt="Status" src="https://img.shields.io/badge/status-early%20development-yellow">
</p>

## What is Clarus?

Clarus turns a PDF into something you actively study rather than passively
scroll through. It parses a document's real structure — chapters and
sections, not just pages — and builds a reading companion around it:
adjustable summaries, periodic comprehension questions, and chapter-end
recaps that connect ideas back to earlier chapters instead of summarizing
each one in isolation.

A context-aware chat panel sits alongside the reader. Highlight a passage
and ask about it directly — the current section, and related passages
pulled from elsewhere in the document when relevant, come along
automatically, so explanations stay grounded in what you're reading.

## Status

Early development. The core architecture — the LLM provider abstraction,
the local storage layer, the three-pane SwiftUI interface — is in place.
PDF ingestion, digest generation, and chat are being wired up feature by
feature from there. Not yet ready for daily use.

## Planned features

- Adjustable summaries at the paragraph, section, and chapter level
- Comprehension questions with configurable frequency (v1: multiple choice)
- Context-aware chat, triggered by highlighting text
- Chapter-end summaries with cross-chapter connections
- Local-first storage — notes, highlights, and the retrieval index never
  leave your machine
- Swappable LLM backend — AWS Bedrock by default, with room for a direct
  API or a fully local model
- Read-aloud, via macOS's native speech synthesis (in design)

## Architecture

- **`LLMProvider` protocol** — every LLM call goes through this, so
  Bedrock, a direct API, or a local model are interchangeable without
  touching the rest of the app.
- **SQLite + sqlite-vec** — relational data and vector embeddings live in
  one local database file. No server, no external database to run.
- **SwiftUI, three-pane layout** — outline sidebar, PDF viewer, digest
  panel, with chat as an attached panel rather than a separate window.

## v1 scope

- Comprehension questions are multiple-choice only.
- No OCR — PDFs need an embedded outline and text layer to be ingested.
- The embedding index is local only; no server-based database.

## Tech stack

Swift · SwiftUI · PDFKit · [GRDB.swift](https://github.com/groue/GRDB.swift) · [sqlite-vec](https://github.com/asg017/sqlite-vec) · AWS Bedrock

## Getting started

1. Xcode 15+, macOS 14+ deployment target.
2. Clone the repo and open it in Xcode.
3. Add package dependencies: GRDB.swift and sqlite-vec (see each
   project's "loadable extension" setup instructions).
4. In Signing & Capabilities, enable read access for user-selected files
   (opening PDFs) and outgoing network connections (LLM calls).
5. Configure AWS Bedrock credentials/region — see `Services/LLMProvider.swift`.
6. Build and run.

## Roadmap

Near-term priorities: persistent notes/highlights/bookmarks, citation-
backed answers with page jumps, unified search across document text and
chat history, flashcard export, and read-aloud.

## Contributing

This is currently a personal project built incrementally in the open.
Issues and suggestions are welcome; contribution guidelines will follow
once the core feature set stabilizes.

## License

MIT License.