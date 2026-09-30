import Foundation
import Testing
@testable import GlideCore

@Test func catalogSortingUsesServerFieldsAndPersistsDirection() throws {
    let order = CatalogOrder(sort: .rating, descending: true)
    #expect(order.query["SortBy"] == "CommunityRating,SortName")
    #expect(order.query["SortOrder"] == "Descending")
    #expect(try JSONDecoder().decode(CatalogOrder.self, from: JSONEncoder().encode(order)) == order)
    #expect(CatalogOrder().query["SortBy"] == "SortName")
    #expect(CatalogSort.added.field == "DateCreated")
}
@Test func hardwareProfileDoesNotAdvertiseUnsupportedVideoCodecs() {
    let body = JellyfinPlaybackPolicy.body(userID: "user", quality: .automatic, directVideoCodecs: "h264")
    let profile = body["DeviceProfile"] as! [String: Any]
    let direct = profile["DirectPlayProfiles"] as! [[String: Any]]
    #expect(direct[0]["VideoCodec"] as? String == "h264")
}
