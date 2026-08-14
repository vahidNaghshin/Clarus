import Foundation
import GRDB   // SPM package: https://github.com/groue/GRDB.swift

/// Local vector + relational store, backed by SQLite. Loads the
/// sqlite-vec extension (https://github.com/asg017/sqlite-vec) at
/// connection time to get vector similarity search without running a
/// separate database server — everything lives in one file inside the
/// app's Application Support directory.
final class EmbeddingStore {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // Loads the compiled sqlite-vec extension bundled with the app.
            try db.execute(sql: "PRAGMA load_extension('vec0')")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chunks (
                    id TEXT PRIMARY KEY,
                    document_id TEXT NOT NULL,
                    section_id TEXT NOT NULL,
                    text TEXT NOT NULL
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vectors USING vec0(
                    embedding float[1536]
                );
                """)
        }
    }

    /// Stores a chunk of section text alongside its embedding.
    func insert(chunkID: String, documentID: String, sectionID: String,
                text: String, embedding: [Float]) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO chunks (id, document_id, section_id, text) VALUES (?, ?, ?, ?)",
                arguments: [chunkID, documentID, sectionID, text])
            let embeddingData = Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)
            try db.execute(
                sql: "INSERT INTO chunk_vectors (rowid, embedding) VALUES (?, ?)",
                arguments: [chunkID, embeddingData])
        }
    }

    /// Nearest-neighbour search — this is what powers "connections to
    /// other chapters" and chat's whole-document retrieval.
    func nearest(to queryEmbedding: [Float], documentID: String, limit: Int = 5) throws -> [String] {
        try dbQueue.read { db in
            let queryData = Data(bytes: queryEmbedding, count: queryEmbedding.count * MemoryLayout<Float>.size)
            return try String.fetchAll(db, sql: """
                SELECT chunks.text FROM chunk_vectors
                JOIN chunks ON chunks.id = chunk_vectors.rowid
                WHERE chunks.document_id = ?
                ORDER BY vec_distance_cosine(embedding, ?) ASC
                LIMIT ?
                """, arguments: [documentID, queryData, limit])
        }
    }
}
