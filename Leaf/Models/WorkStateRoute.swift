//  WorkStateRoute.swift
//  Track 7 P3 — coordinator destination for the Work State detail screen.
//  Distinct type (not a HomeSurface case) per master spec §6 and
//  RouteCoordinator.swift comment: "WorkStateCard etc. would push their own
//  destination types in P7+".
//
//  Zero-field struct keeps the door open for v1.1 deep-link parameters
//  (e.g. preselected sub-tab) without breaking the navigationDestination
//  binding.

import Foundation

struct WorkStateRoute: Hashable, Sendable {}
