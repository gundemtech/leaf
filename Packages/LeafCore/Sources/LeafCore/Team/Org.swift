import Foundation

/// Phase Track-5 S2 — `Org` retained as backward-compatibility typealias
/// during the S2 multi-workspace migration. New code uses `Workspace`.
/// This typealias is deleted in Task 12 of the S2 refactor sequence once
/// all consumers have migrated. See `Workspace.swift` for the canonical
/// type definition.
public typealias Org = Workspace
