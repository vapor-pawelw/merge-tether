/// The initial catalog sync is distinct from later background refreshes.
enum BoardRefreshState: Equatable {
    case syncing, unavailable, current

    init(todosReady: Bool, catalogReady: Bool, authoredReady: Bool,
         isRefreshing: Bool, hasError: Bool) {
        if todosReady && catalogReady && authoredReady { self = .current }
        else { self = isRefreshing || !hasError ? .syncing : .unavailable }
    }
}
