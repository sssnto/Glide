import Foundation
import Testing
@testable import GlideCore

@Test func personnelDecodeKeepsIdentityAndImageWithoutRequiringThem() throws {
    let data = Data(#"[{"Name":"同名","Type":"Actor","Role":"主角","Id":"a","PrimaryImageTag":"photo"},{"Name":"同名","Type":"Director","Id":"b"},{"Name":"旧记录","Type":"Writer"}]"#.utf8)
    let people = try JSONDecoder().decode([CatalogItem.Person].self, from: data)
    #expect(people[0].personID == "a")
    #expect(people[1].personID == "b")
    #expect(people[0].PrimaryImageTag == "photo")
    #expect(people[0].credit == "主角")
    #expect(people[1].credit == "导演")
    #expect(people[2].personID == nil)
    #expect(people[2].credit == "编剧")
}
@Test func relatedMediaUsesExactPersonAcrossPagesAndRetainsUserPermissions() throws {
    for start in [0, 60, 120] {
        let query = try PersonMediaQuery.items(userID: "viewer", personID: "person-a", start: start)
        #expect(query["PersonIds"] == "person-a")
        #expect(query["UserId"] == "viewer")
        #expect(query["StartIndex"] == String(start))
        #expect(query["ParentId"] == nil)
        #expect(query["SearchTerm"] == nil)
        #expect(query["IncludeItemTypes"]?.contains("Series") == true)
    }
    #expect(throws: MediaError.self) { try PersonMediaQuery.items(userID: "viewer", personID: "  ", start: 0) }
}

@Test func personMediaExcludesIndividualEpisodes() throws {
    let query = try PersonMediaQuery.items(userID: "viewer", personID: "actor", start: 60)
    let types = query["IncludeItemTypes"]!.split(separator: ",")
    #expect(types.contains("Series"))
    #expect(!types.contains("Episode"))
}
