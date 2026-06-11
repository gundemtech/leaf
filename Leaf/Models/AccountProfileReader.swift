//
//  AccountProfileReader.swift
//  Leaf
//
//  Track 5 — @Observable wrapper that loads the Supabase account identity
//  (GET /auth/v1/user) for the Profile surface. Thin: all decode/format logic
//  lives in LeafCore (SupabaseUserProfile / AccountProfileFormat).
//

import LeafCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AccountProfileReader {
  enum State: Equatable {
    case idle
    case loading
    case loaded(SupabaseUserProfile)
    case failed(String)
  }

  private(set) var state: State = .idle
  private let supabase: SupabaseClient

  init(supabase: SupabaseClient) {
    self.supabase = supabase
  }

  /// Fetch the account identity. Non-fatal on failure (identity is not
  /// gate-critical) — keeps the last loaded value if any, else records `.failed`.
  func load() async {
    if case .loaded = state {} else { state = .loading }
    do {
      state = .loaded(try await supabase.fetchUserProfile())
    } catch {
      if case .loaded = state { return }  // keep prior identity on refresh failure
      state = .failed(String(describing: error))
    }
  }
}
