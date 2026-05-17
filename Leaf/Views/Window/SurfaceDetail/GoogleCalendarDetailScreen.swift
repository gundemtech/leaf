//
//  GoogleCalendarDetailScreen.swift
//  Track 7 P2 — Google Calendar detail. Carve-out per spec §3.5: the
//  screen renders only LeafEmptyState today and does NOT use
//  SurfaceDetailLayout, because the GCP verification gate is still open.
//  GoogleCalendarDetailViewModel is constructed (and remains fully wired
//  end-to-end) so the only edit to ship real aggregates later is this
//  screen file.
//

import SwiftUI
import LeafCore

struct GoogleCalendarDetailScreen: View {
    @State private var vm: GoogleCalendarDetailViewModel

    init(vm: GoogleCalendarDetailViewModel = GoogleCalendarDetailViewModel()) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Detail view coming after GCP gate clears",
                description: "Calendar capture requires Google Cloud Platform project verification (in progress). Detail aggregates land in a follow-up phase."
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
        .navigationTitle(HomeSurface.calendar.displayName)
    }
}
