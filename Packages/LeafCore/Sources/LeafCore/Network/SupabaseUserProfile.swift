//
//  SupabaseUserProfile.swift
//  LeafCore
//
//  Account identity as returned by GET /auth/v1/user (GoTrue). Mirrors the
//  fields the web dashboard reads from session.user. Decode-only value type.
//

import Foundation

public struct SupabaseUserProfile: Sendable, Equatable {
  public let id: UUID?
  public let email: String?
  /// full_name → name → user_name, first non-nil (matches the web dash order).
  public let fullName: String?
  /// app_metadata.provider (e.g. "email" / "google" / "github"); nil if absent.
  public let provider: String?
  /// Raw ISO-8601 created_at string from GoTrue (formatted for display elsewhere).
  public let createdAt: String?

  public init(
    id: UUID?, email: String?, fullName: String?, provider: String?, createdAt: String?
  ) {
    self.id = id
    self.email = email
    self.fullName = fullName
    self.provider = provider
    self.createdAt = createdAt
  }
}

extension SupabaseUserProfile: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id, email, created_at, app_metadata, user_metadata
  }
  private struct AppMeta: Decodable { let provider: String? }
  private struct UserMeta: Decodable {
    let full_name: String?
    let name: String?
    let user_name: String?
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let idString = try c.decodeIfPresent(String.self, forKey: .id)
    self.id = idString.flatMap(UUID.init(uuidString:))
    self.email = try c.decodeIfPresent(String.self, forKey: .email)
    self.createdAt = try c.decodeIfPresent(String.self, forKey: .created_at)
    let app = try c.decodeIfPresent(AppMeta.self, forKey: .app_metadata)
    self.provider = app?.provider
    let um = try c.decodeIfPresent(UserMeta.self, forKey: .user_metadata)
    self.fullName = um?.full_name ?? um?.name ?? um?.user_name
  }
}
