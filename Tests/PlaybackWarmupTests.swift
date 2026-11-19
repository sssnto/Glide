import Foundation
import Testing
@testable import GlideCore

struct PlaybackWarmupTests {
    @Test func windowFollowsSwipeAndDoesNotWrapOrIncludeCurrent() {
        #expect(PlaybackWarmupPolicy.indices(current: 3, count: 8) == [4, 5, 2])
        #expect(PlaybackWarmupPolicy.indices(current: 3, count: 8, direction: -1) == [2, 1, 4])
        #expect(PlaybackWarmupPolicy.indices(current: 0, count: 8) == [1, 2])
        #expect(PlaybackWarmupPolicy.indices(current: 7, count: 8) == [6])
        #expect(PlaybackWarmupPolicy.indices(current: 0, count: 1).isEmpty)
        #expect(PlaybackWarmupPolicy.indices(current: -1, count: 8).isEmpty)
        #expect(PlaybackWarmupPolicy.indices(current: 8, count: 8).isEmpty)
    }
    @Test func expensiveConstrainedAndLowPowerDoNotSpendPrefetchTraffic() {
        #expect(PlaybackWarmupPolicy.allowsNetwork(satisfied: true, wifi: true, expensive: false, constrained: false, lowPower: false))
        for excluded in 0..<5 {
            #expect(!PlaybackWarmupPolicy.allowsNetwork(satisfied: excluded != 0, wifi: excluded != 1, expensive: excluded == 2, constrained: excluded == 3, lowPower: excluded == 4))
        }
    }
    @Test func cacheServesOnlyPresentBytesAndPreservesGap() throws {
        var cache = try #require(PlaybackStartupBytes(head: Data([0, 1, 2, 3]), length: 12, validator: "v1"))
        let insertion1 = cache.appendTail(Data([8, 9, 10, 11]), offset: 8, length: 12, validator: "v1")
        #expect(insertion1)
        #expect(cache.prefix(offset: 1, count: 100) == Data([1, 2, 3]))
        #expect(cache.prefix(offset: 5, count: 100).isEmpty)
        #expect(cache.prefix(offset: 9, count: 100) == Data([9, 10, 11]))
        #expect(cache.prefix(offset: 12, count: 100).isEmpty)
        #expect(cache.prefix(offset: -1, count: 100).isEmpty)
        #expect(cache.prefix(offset: 0, count: Int.max) == cache.head)
        #expect(cache.byteCount == 8)
    }
    @Test func changedOrInvalidTailCannotMixFileVersions() throws {
        var cache = try #require(PlaybackStartupBytes(head: Data([0, 1]), length: 8, validator: "v1"))
        let insertion2 = cache.appendTail(Data([6, 7]), offset: 6, length: 8, validator: "v2")
        #expect(!insertion2)
        let insertion3 = cache.appendTail(Data([6, 7]), offset: 6, length: 9, validator: "v1")
        #expect(!insertion3)
        let insertion4 = cache.appendTail(Data([0, 1]), offset: -2, length: 8, validator: "v1")
        #expect(!insertion4)
        let insertion5 = cache.appendTail(Data([0, 1]), offset: 1, length: 8, validator: "v1")
        #expect(!insertion5)
        let insertion6 = cache.appendTail(Data([6]), offset: 6, length: 8, validator: "v1")
        #expect(!insertion6)
        #expect(cache.tail == nil)
    }
    @Test func cachesHaveFixedMemoryBounds() throws {
        #expect(PlaybackStartupBytes(head: Data(), length: 5, validator: nil) == nil)
        #expect(PlaybackStartupBytes(head: Data([1, 2]), length: 1, validator: nil) == nil)
        #expect(PlaybackStartupBytes(head: Data(count: PlaybackWarmupPolicy.headBytes + 1), length: 90_000_000, validator: nil) == nil)
        var cache = try #require(PlaybackStartupBytes(head: Data(count: PlaybackWarmupPolicy.headBytes), length: 90_000_000, validator: nil))
        let insertion7 = cache.appendTail(Data(count: PlaybackWarmupPolicy.tailBytes + 1), offset: 90_000_000 - Int64(PlaybackWarmupPolicy.tailBytes + 1), length: 90_000_000, validator: nil)
        #expect(!insertion7)
        let insertion8 = cache.appendTail(Data(count: PlaybackWarmupPolicy.tailBytes), offset: 90_000_000 - Int64(PlaybackWarmupPolicy.tailBytes), length: 90_000_000, validator: nil)
        #expect(insertion8)
        #expect(cache.byteCount * PlaybackWarmupPolicy.maximumItems <= 51_118_080)
    }
    @Test func fourKCacheTargetsAdaptToBitrateAndRemainBounded() {
        #expect(PlaybackWarmupPolicy.segmentedSeconds(bitrate: 16_000_000) == 16)
        #expect(PlaybackWarmupPolicy.segmentedSeconds(bitrate: 32_000_000) > 8)
        #expect(PlaybackWarmupPolicy.segmentedSeconds(bitrate: 200_000_000) == 4)
        #expect(PlaybackWarmupPolicy.segmentedSeconds(bitrate: nil) == 8)
    }
    @Test func progressiveGrowthDoesNotMixRevisionsOrRetainOverlappingTail() throws {
        var cache = try #require(PlaybackStartupBytes(head: Data([0, 1]), length: 8, validator: "v1"))
        let tail = cache.appendTail(Data([6, 7]), offset: 6, length: 8, validator: "v1")
        #expect(tail)
        let changed = cache.appendHead(Data([2, 3]), offset: 2, length: 8, validator: "v2")
        #expect(!changed && cache.head == Data([0, 1]))
        let gap = cache.appendHead(Data([4, 5]), offset: 4, length: 8, validator: "v1")
        #expect(!gap)
        let grown = cache.appendHead(Data([2, 3, 4, 5, 6, 7]), offset: 2, length: 8, validator: "v1")
        #expect(grown && cache.tail == nil && cache.byteCount == 8)
        cache.trimHead(to: 4)
        #expect(cache.prefix(offset: 0, count: 8) == Data([0, 1, 2, 3]))
        #expect(cache.prefix(offset: 4, count: 4).isEmpty)
    }
    @Test func rangeValidationRejectsWrongOffsetOversizeAndUnknownTotal() {
        let valid = PlaybackStartupBytes.range("bytes 100-199/1000", offset: 100, maximum: 100)
        #expect(valid?.bytes == 100 && valid?.length == 1000)
        for invalid in ["bytes 0-99/1000", "bytes 100-200/1000", "bytes 100-99/1000", "bytes 100-199/199", "bytes 100-199/*", "bytes */1000", "bytes -1-99/1000", "garbage"] {
            #expect(PlaybackStartupBytes.range(invalid, offset: 100, maximum: 100) == nil)
        }
    }
}
