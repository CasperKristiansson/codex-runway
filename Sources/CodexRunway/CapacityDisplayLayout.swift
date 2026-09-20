import Foundation

enum CapacityDisplayLayout {
    static let maximumHistoryRows = 7
    static let rowHeight: CGFloat = 21
    static let headerHeight: CGFloat = 18
    static let resetSectionHeight: CGFloat = 24
    static let rowsHeight = CGFloat(maximumHistoryRows) * rowHeight

    // Header, divider and seven rows. Overview scrolls its reset events within
    // this same area rather than increasing the menu's height.
    static let height = headerHeight + 8 + rowsHeight

}
