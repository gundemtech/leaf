// Phase Track-6 P2 — RunDestinationBucket heuristic coverage.
import Testing

@testable import LeafCore

@Suite("RunDestinationBucket heuristics")
struct RunDestinationBucketTests {
    @Test func myMac_macos() {
        #expect(RunDestinationBucket.bucket(rawName: "My Mac") == .macos)
    }
    @Test func anyMac_macos() {
        #expect(RunDestinationBucket.bucket(rawName: "Any Mac") == .macos)
    }
    @Test func myMacDesignedForIPad_macos() {
        #expect(RunDestinationBucket.bucket(rawName: "My Mac (Designed for iPad)") == .macos)
    }
    @Test func myMacbookPro_unknown_notMacos() {
        // Defense against substring `contains("My Mac")` over-matching custom
        // Xcode destination names. "My Macbook Pro" is NOT Xcode's canonical
        // Mac destination — bucket exact-match guards against false positives.
        #expect(RunDestinationBucket.bucket(rawName: "My Macbook Pro") == .unknown)
    }
    @Test func iPhoneSimulator_iosSimulator() {
        #expect(RunDestinationBucket.bucket(rawName: "iPhone 16 Pro (Simulator)") == .iosSimulator)
    }
    @Test func iPhoneDevice_iosDevice() {
        #expect(RunDestinationBucket.bucket(rawName: "Dmitrii's iPhone") == .iosDevice)
    }
    @Test func iPad_iosDevice() {
        #expect(RunDestinationBucket.bucket(rawName: "Dmitrii's iPad") == .iosDevice)
    }
    @Test func iPadSimulator() {
        #expect(RunDestinationBucket.bucket(rawName: "iPad Pro 13-inch (M4) (Simulator)") == .iosSimulator)
    }
    @Test func appleWatchSimulator_watchSimulator() {
        #expect(RunDestinationBucket.bucket(rawName: "Apple Watch Series 10 (Simulator)") == .watchSimulator)
    }
    @Test func appleWatchDevice() {
        #expect(RunDestinationBucket.bucket(rawName: "Apple Watch Ultra 2 (49mm)") == .watchDevice)
    }
    @Test func appleTV_tvDevice() {
        #expect(RunDestinationBucket.bucket(rawName: "Apple TV 4K (3rd generation)") == .tvDevice)
    }
    @Test func appleTVSimulator() {
        #expect(RunDestinationBucket.bucket(rawName: "Apple TV 4K (Simulator)") == .tvSimulator)
    }
    @Test func visionPro_visionDevice() {
        #expect(RunDestinationBucket.bucket(rawName: "Vision Pro") == .visionDevice)
    }
    @Test func visionSimulator() {
        #expect(RunDestinationBucket.bucket(rawName: "Vision Pro (Simulator)") == .visionSimulator)
    }
    @Test func nilName_unknown() {
        #expect(RunDestinationBucket.bucket(rawName: nil) == .unknown)
    }
    @Test func parenthesisNone_unknown() {
        #expect(RunDestinationBucket.bucket(rawName: "(none)") == .unknown)
    }
    @Test func empty_unknown() {
        #expect(RunDestinationBucket.bucket(rawName: "") == .unknown)
    }
    @Test func whitespaceOnly_unknown() {
        #expect(RunDestinationBucket.bucket(rawName: "   ") == .unknown)
    }
    @Test func rawValuesAreStableSnakeCase() {
        // Locks the public wire format. Any rename here is a breaking change.
        #expect(RunDestinationBucket.macos.rawValue == "macos")
        #expect(RunDestinationBucket.iosSimulator.rawValue == "ios_simulator")
        #expect(RunDestinationBucket.iosDevice.rawValue == "ios_device")
        #expect(RunDestinationBucket.tvSimulator.rawValue == "tv_simulator")
        #expect(RunDestinationBucket.tvDevice.rawValue == "tv_device")
        #expect(RunDestinationBucket.watchSimulator.rawValue == "watch_simulator")
        #expect(RunDestinationBucket.watchDevice.rawValue == "watch_device")
        #expect(RunDestinationBucket.visionSimulator.rawValue == "vision_simulator")
        #expect(RunDestinationBucket.visionDevice.rawValue == "vision_device")
        #expect(RunDestinationBucket.unknown.rawValue == "unknown")
    }
}
