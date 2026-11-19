import Foundation

enum CatalogSort: String, CaseIterable, Identifiable, Codable {
    case name, rating, year, added, runtime, size
    var id: String { rawValue }
    var title: String { switch self { case .name: return "名称"; case .rating: return "评分"; case .year: return "发行年份"; case .added: return "添加时间"; case .runtime: return "片长"; case .size: return "文件大小" } }
    var field: String { switch self { case .name, .size: return "SortName"; case .rating: return "CommunityRating"; case .year: return "ProductionYear"; case .added: return "DateCreated"; case .runtime: return "Runtime" } }
}
struct CatalogOrder: Codable, Equatable {
    var sort: CatalogSort = .name
    var descending = false
    var query: [String: String] { ["SortBy": sort.field + (sort == .name || sort == .size ? "" : ",SortName"), "SortOrder": descending && sort != .size ? "Descending" : "Ascending"] }
    var key: String { sort.rawValue + String(descending) }
    func sortedBySize(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted {
            if let result=MediaFileSize.precedes($0.fileSize,$1.fileSize,descending:descending) { return result }
            let order=$0.Name.localizedStandardCompare($1.Name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
