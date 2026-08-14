-- Relational metadata. Vector search lives alongside it in the same
-- SQLite file via the sqlite-vec virtual table (see EmbeddingStore.swift).

CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    file_path TEXT NOT NULL,
    page_count INTEGER NOT NULL,
    imported_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chapters (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id),
    title TEXT NOT NULL,
    page_start INTEGER NOT NULL,
    page_end INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sections (
    id TEXT PRIMARY KEY,
    chapter_id TEXT NOT NULL REFERENCES chapters(id),
    title TEXT NOT NULL,
    page_start INTEGER NOT NULL,
    page_end INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS summaries (
    id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,        -- a section or chapter id
    text TEXT NOT NULL,
    style TEXT NOT NULL,
    generated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS questions (
    id TEXT PRIMARY KEY,
    section_id TEXT NOT NULL REFERENCES sections(id),
    prompt TEXT NOT NULL,
    options TEXT NOT NULL,          -- JSON array, v1 is multiple-choice only
    correct_index INTEGER NOT NULL,
    user_answer_index INTEGER
);

CREATE TABLE IF NOT EXISTS chat_messages (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id),
    section_id TEXT,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    timestamp TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id),
    section_id TEXT,
    text TEXT NOT NULL,
    source_chat_message_id TEXT,
    created_at TEXT NOT NULL
);

-- chunks + chunk_vectors (the vec0 virtual table) are created by
-- EmbeddingStore at first launch, since the vec0 module must be loaded
-- before CREATE VIRTUAL TABLE will succeed.
