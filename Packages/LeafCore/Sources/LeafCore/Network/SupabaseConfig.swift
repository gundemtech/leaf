//
//  SupabaseConfig.swift
//  LeafCore
//
//  Track 5 / S3 — reads Supabase project URL + anon key from app Bundle Info.plist.
//  Anon key is a public JWT-like signed token — safe to embed in clients. RLS is
//  the security boundary, not this key.
//

import Foundation

public enum SupabaseConfig {
    public static func baseURL(from bundle: Bundle = .main) -> URL {
        guard let s = bundle.object(forInfoDictionaryKey: "LeafSupabaseURL") as? String,
              let url = URL(string: s) else {
            preconditionFailure("LeafSupabaseURL missing or malformed in Info.plist")
        }
        return url
    }

    public static func anonKey(from bundle: Bundle = .main) -> String {
        guard let s = bundle.object(forInfoDictionaryKey: "LeafSupabaseAnonKey") as? String,
              !s.isEmpty else {
            preconditionFailure("LeafSupabaseAnonKey missing in Info.plist")
        }
        return s
    }
}
