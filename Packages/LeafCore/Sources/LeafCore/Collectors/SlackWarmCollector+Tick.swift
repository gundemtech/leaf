//
//  SlackWarmCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration moved
//  out of SlackWarmCollector.swift. Pure relocation; no behavioural change.
//

import Foundation

extension SlackWarmCollector {
    @discardableResult
    public func performTick(now: Date? = nil) async -> TickResult {
        let tickNow = now ?? clock()
        let nowMs = Int64(tickNow.timeIntervalSince1970 * 1000)

        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .slack)
        } catch {
            logger.error("warm readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await tokenRefresher.refreshIfNeeded(now: tickNow)
        } catch SlackTokenRefresherError.refreshDenied(let msg) {
            logger.warning("warm refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("warm refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        // 3. Resolve workspaceID + userID. Prefer integration record (single
        // source of truth in production) but fall back to closures supplied
        // at construction time (tests / Agent wiring).
        let teamID: String
        let userID: String
        let parts = refreshed.workspaceID.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            teamID = String(parts[0])
            userID = String(parts[1])
        } else if let w = workspaceIDProvider(), let u = userIDProvider() {
            teamID = w
            userID = u
        } else {
            logger.error(
                "malformed workspaceID '\(refreshed.workspaceID, privacy: .public)' — expected '<team>:<user>'")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        let sourceID = "slack:warm:\(teamID):\(userID)"

        // 4. Read cursor + prior snapshots.
        let cursor =
            (try? database.readOffset(
                collectorID: CollectorID.slackWarmPolling,
                sourceID: sourceID
            ))?.lastModifiedMs

        let priorMemberChannels: SlackMemberChannelsTopList? =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackMemberChannels)
        let priorPins: [SlackChannelPinsSnapshot] =
            readSnapshotArray(kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel)
        let priorPinsRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel)
        let priorBookmarks: [SlackChannelBookmarksSnapshot] =
            readSnapshotArray(kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel)
        let priorBookmarksRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel)
        let priorReminders: SlackRemindersSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackReminders) ?? .empty
        let priorRemindersRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackReminders)
        let priorScheduled: SlackScheduledMessagesSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackScheduledMessages) ?? .empty
        let priorScheduledRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackScheduledMessages)
        let priorStars: SlackStarsSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackStars) ?? .empty
        let priorStarsRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackStars)

        // 5. Fetch warm state from provider. Per-endpoint failure tolerance
        // lives inside the provider impl; a top-level throw aborts the tick
        // entirely and leaves the cursor unchanged so the next tick retries.
        let batch: SlackWarmBatch
        do {
            batch = try await provider.fetchWarmState(
                accessToken: refreshed.accessToken,
                userID: userID,
                scopes: scopes,
                priors: SlackWarmStatePriorSnapshots(
                    memberChannels: priorMemberChannels,
                    pinsPerChannel: priorPins,
                    bookmarksPerChannel: priorBookmarks,
                    reminders: priorReminders,
                    scheduledMessages: priorScheduled,
                    stars: priorStars
                ),
                since: cursor,
                now: nowMs
            )
        } catch {
            logger.error("fetchWarmState failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }

        // 6. Diff source = FULL member set from provider (persisted as-is to
        //    `slackMemberChannels`). Top-N fan-out cap for per-channel sub-fans
        //    (pins / bookmarks) is the provider's internal responsibility —
        //    it consumes `priorMemberChannels` for its own ranking.
        //    C3 review fix: persisting the cap caused false-positive join/left
        //    events on rank churn (>10 active channels).
        let fullMemberSet = batch.memberChannelsTopList

        // 7. Build events.
        var events: [RawEvent] = []
        let workspaceID = teamID

        // 7a. Channel joined/left — diff on FULL set, not top-N cap.
        if await scopes.has("channels:read") {
            let diff = Self.userConversationsDiff(prior: priorMemberChannels, current: fullMemberSet)
            for ch in diff.joined {
                events.append(
                    Self.makeChannelJoinedEvent(
                        channel: ch, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
            for ch in diff.left {
                events.append(
                    Self.makeChannelLeftEvent(
                        channel: ch, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
        }

        // 7b. Reactions (provider's `since` cursor filters new reactions —
        // bootstrap discipline lives in provider impl; collector treats each
        // reaction in the batch as a fresh observation).
        if await scopes.has("reactions:read") {
            for r in batch.reactions.reactions {
                events.append(
                    Self.makeReactionAddedEvent(
                        reaction: r, workspaceID: workspaceID, userID: userID
                    ))
            }
        }

        // 7c. Pins per channel — bootstrap-per-channel discipline. The diff
        // helper skips channels with no prior row, so first-tick channels emit
        // nothing. Additionally gate emission on the snapshot row's existence
        // to suppress events before the first persisted snapshot.
        if await scopes.has("pins:read"), priorPinsRowPresent {
            let (added, removed) = Self.pinsPerChannelDiff(prior: priorPins, current: batch.pinsPerChannel)
            for entry in added {
                events.append(
                    Self.makePinAddedEvent(
                        channelID: entry.channelID, itemRef: entry.itemRef,
                        workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
            for entry in removed {
                events.append(
                    Self.makePinRemovedEvent(
                        channelID: entry.channelID, itemRef: entry.itemRef,
                        workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
        }

        // 7d. Bookmarks per channel.
        if await scopes.has("bookmarks:read"), priorBookmarksRowPresent {
            let (added, removed) = Self.bookmarksPerChannelDiff(
                prior: priorBookmarks, current: batch.bookmarksPerChannel)
            for bm in added {
                events.append(
                    Self.makeBookmarkAddedEvent(
                        bookmark: bm, workspaceID: workspaceID, userID: userID
                    ))
            }
            for bm in removed {
                events.append(
                    Self.makeBookmarkRemovedEvent(
                        bookmark: bm, workspaceID: workspaceID, userID: userID
                    ))
            }
        }

        // 7e. Reminders.
        if await scopes.has("reminders:read"), priorRemindersRowPresent {
            let (created, completed) = Self.remindersDiff(prior: priorReminders, current: batch.reminders)
            for r in created {
                events.append(
                    Self.makeReminderCreatedEvent(
                        reminder: r, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
            for r in completed {
                events.append(
                    Self.makeReminderCompletedEvent(
                        reminder: r, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
        }

        // 7f. Scheduled messages. Slack's `chat.scheduledMessages.list` scope
        // is implicit on `chat:write` for the authoring user — gate on that
        // canonical scope.
        if await scopes.has("chat:write"), priorScheduledRowPresent {
            let (scheduled, sent) = Self.scheduledMessagesDiff(prior: priorScheduled, current: batch.scheduledMessages)
            for m in scheduled {
                events.append(
                    Self.makeMessageScheduledEvent(
                        message: m, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
            for m in sent {
                events.append(
                    Self.makeMessageSentScheduledEvent(
                        message: m, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
        }

        // 7g. Stars (saved items).
        if await scopes.has("stars:read"), priorStarsRowPresent {
            let (saved, unsaved) = Self.starsDiff(prior: priorStars, current: batch.stars)
            for item in saved {
                events.append(
                    Self.makeItemSavedEvent(
                        item: item, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
            for item in unsaved {
                events.append(
                    Self.makeItemUnsavedEvent(
                        item: item, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                    ))
            }
        }

        // 8. Build offset + snapshots.
        let offset = CollectorOffset(
            collectorID: CollectorID.slackWarmPolling,
            sourceID: sourceID,
            byteOffset: 0, inode: nil, size: 0,
            lastModifiedMs: nowMs, updatedMs: nowMs
        )

        let snapshots: [ProviderSnapshot] = [
            // Persist the FULL member set — diff source for join/left + fan-out
            // root for cold tier (cold caps locally via rankTop10ByLatestTs).
            // C3 review fix: previously persisted top-10 cap caused false-
            // positive transitions on rank churn.
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackMemberChannels,
                encoding: fullMemberSet,
                nowMs: nowMs),
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel,
                encoding: batch.pinsPerChannel, nowMs: nowMs),
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel,
                encoding: batch.bookmarksPerChannel, nowMs: nowMs),
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackReminders,
                encoding: batch.reminders, nowMs: nowMs),
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackScheduledMessages,
                encoding: batch.scheduledMessages, nowMs: nowMs),
            makeSnapshot(
                kind: Schema.ProviderSnapshotKinds.slackStars,
                encoding: batch.stars, nowMs: nowMs),
        ]

        // 9. Atomic write.
        do {
            try database.writeEventsOffsetsAndSnapshots(
                events: events, offsets: [offset], snapshots: snapshots
            )
        } catch {
            logger.error("warm persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("slack warm tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }
}
