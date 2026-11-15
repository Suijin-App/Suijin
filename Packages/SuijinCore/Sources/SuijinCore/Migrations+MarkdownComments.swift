import GRDB

extension Migrations {
    /// Comments on spans of Markdown files (`v9_markdown_comment`). Only adds a table.
    static func registerMarkdownCommentMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9_markdown_comment") { db in
            try db.create(table: "markdown_comment") { t in
                t.primaryKey("id", .blob)
                // Comments go with their workspace or worktree.
                t.column("workspaceID", .blob).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("worktreeID", .blob).indexed()
                    .references("worktree", onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("body", .text).notNull()
                t.column("quote", .text).notNull()
                t.column("prefix", .text).notNull()
                t.column("suffix", .text).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("isDetached", .boolean).notNull().defaults(to: false)
                t.column("status", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double)
                t.column("sentAt", .double)
                // The receiving agent session. No foreign key: the comment outlives the session record.
                t.column("sentToSession", .blob)
                t.column("resolvedAt", .double)
                t.column("agentReply", .text)
                t.check(sql: "startOffset >= 0 AND endOffset > startOffset AND startLine >= 1 AND endLine >= startLine")
            }
            try db.create(index: "markdown_comment_on_context_file", on: "markdown_comment",
                          columns: ["workspaceID", "worktreeID", "filePath"])
            try db.create(index: "markdown_comment_on_sentToSession", on: "markdown_comment", columns: ["sentToSession"])
        }
    }
}
