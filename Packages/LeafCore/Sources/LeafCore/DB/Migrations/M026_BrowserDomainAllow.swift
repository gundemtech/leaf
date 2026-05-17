// Phase Track-6 P3 — per-domain allow-list table for browser URL granularity
// control. See docs/superpowers/specs/2026-05-16-track-6-P3-browsers-deep.md §4.
// Default empty; non-matching domains resolve to `domainOnly` at filter time.

import Foundation
import GRDB

extension DatabaseMigrator {
    public mutating func registerMigration026BrowserDomainAllow() {
        registerMigration("026_browser_domain_allow") { db in
            try db.create(table: Schema.BrowserDomainAllow.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.BrowserDomainAllow.domain, .text)
                t.column(Schema.BrowserDomainAllow.granularity, .text).notNull()
                t.column(Schema.BrowserDomainAllow.addedAtMs, .integer).notNull()
                t.column(Schema.BrowserDomainAllow.notes, .text)
                t.check(sql: "\(Schema.BrowserDomainAllow.granularity) IN ('full_url','path_stripped','domain_only')")
            }
        }
    }
}
