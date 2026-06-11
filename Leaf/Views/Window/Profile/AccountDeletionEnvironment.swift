//
//  AccountDeletionEnvironment.swift
//  Leaf
//
//  Custom environment key carrying the AccountDeletionService into ProfileView's
//  Danger zone. Default is a fail-safe no-op that THROWS, so a misconfigured
//  environment can never silently "succeed" a delete.
//

import LeafCore
import SwiftUI

private struct AccountDeletionKey: EnvironmentKey {
  static let defaultValue = AccountDeletionService(
    deleteAccount: { throw CancellationError() },  // never wired in prod
    signOut: {},
    deleteIdentity: {})
}

extension EnvironmentValues {
  var accountDeletion: AccountDeletionService {
    get { self[AccountDeletionKey.self] }
    set { self[AccountDeletionKey.self] = newValue }
  }
}
