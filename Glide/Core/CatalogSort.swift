import Foundation

enum CatalogSort: String, CaseIterable, Identifiable, Codable {
    case name, rating, year, added, runtime
    var id: String { rawValue }
    var title: String { switch self { case .name: return "名称"; case .rating: return "评分"; case .year: return "发行年份"; case .added: return "添加时间"; case .runtime: return "片长" } }
    var field: String { switch self { case .name: return "SortName"; case .rating: return "CommunityRating"; case .year: return "ProductionYear"; case .added: return "DateCreated"; case .runtime: return "Runtime" } }
}
struct CatalogOrder: Codable, Equatable {
    var sort: CatalogSort = .name
    var descending = false
    var query: [String: String] { ["SortBy": sort.field + (sort == .name ? "" : ",SortName"), "SortOrder": descending ? "Descending" : "Ascending"] }
    var key: String { sort.rawValue + String(descending) }
}
