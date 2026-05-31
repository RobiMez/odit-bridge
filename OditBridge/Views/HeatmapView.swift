import SwiftUI

// GitHub-contributions-style calendar heatmap. Cells are coloured by the
// number of synced transactions on that day. Click a cell to jump to the
// Synced tab with the table filtered to that day.
//
// Aggregation is entirely client-side over `state.syncedTransactions` — no
// extra API call. When the dataset grows large enough that aggregating on
// every render hurts, swap to the (not-yet-built) /charts/.../daily-buckets
// endpoint noted in the implementation plan.
struct HeatmapView: View {
    @EnvironmentObject var state: AppState
    @Binding var sidebar: String

    enum Range: String, CaseIterable, Identifiable {
        case w12 = "12 weeks"
        case w52 = "52 weeks"
        case all = "All"
        var id: String { rawValue }
        var weeks: Int? {
            switch self {
            case .w12: return 12
            case .w52: return 52
            case .all: return nil
            }
        }
    }
    @State private var range: Range = .w52

    private struct DayCell: Identifiable, Hashable {
        let date: Date
        let count: Int
        let net: Double
        var id: Date { date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity heatmap")
                        .font(.title3.weight(.semibold))
                    Text("One cell per day · click to filter the Synced view")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $range) {
                    ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            if state.syncedTransactions.isEmpty {
                empty
            } else {
                let grid = computeGrid()
                let maxCount = grid.flatMap { $0 }.map(\.count).max() ?? 0
                gridContainer(grid: grid, maxCount: maxCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                legend(maxCount: maxCount)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func gridContainer(grid: [[DayCell]], maxCount: Int) -> some View {
        let segments = segmentGrid(grid)
        let activeColumns = segments.map(\.activeWeekCount).reduce(0, +)
        let gapBlocks = segments.filter { if case .gap = $0 { return true } else { return false } }.count

        GeometryReader { geo in
            let horizontalPadding: CGFloat = 40   // 20pt each side
            let columnGap: CGFloat = 10            // gap between day-of-week column and the chart
            let available = max(0, geo.size.width - horizontalPadding)

            // Solve for cellSize given:
            //   available = cell + columnGap + activeColumns*cell + (activeColumns-1)*cellSpacing
            //             + gapBlocks * (gapBlockWidth + cellSpacing)
            let gapTotal = CGFloat(gapBlocks) * (gapBlockWidth + cellSpacing)
            let raw = activeColumns > 0
                ? (available - columnGap - gapTotal - cellSpacing * CGFloat(activeColumns - 1))
                  / CGFloat(activeColumns + 1)
                : minCellSize
            let cell = max(minCellSize, min(maxCellSize, raw))
            let needsScroll = raw < minCellSize - 0.5

            let body = HStack(alignment: .top, spacing: columnGap) {
                dayOfWeekColumn(cellSize: cell)
                HStack(alignment: .top, spacing: cellSpacing) {
                    ForEach(segments) { segment in
                        switch segment {
                        case .active(let cols):
                            activeSegment(cols, maxCount: maxCount, cellSize: cell)
                        case .gap(let weeks, let start, let end):
                            gapBlock(weeks: weeks, start: start, end: end, cellSize: cell)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            if needsScroll {
                ScrollView([.horizontal]) {
                    body.padding(.vertical, 12)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    body
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    @ViewBuilder
    private func activeSegment(_ cols: [[DayCell]], maxCount: Int, cellSize: CGFloat) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        HStack(spacing: cellSpacing) {
            ForEach(cols.indices, id: \.self) { i in
                VStack(spacing: cellSpacing) {
                    ForEach(cols[i], id: \.id) { cell in
                        cellView(cell, maxCount: maxCount,
                                 isFuture: cell.date > today, cellSize: cellSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gapBlock(weeks: Int, start: Date, end: Date, cellSize: CGFloat) -> some View {
        let height = cellSize * 7 + cellSpacing * 6
        VStack(spacing: 4) {
            Image(systemName: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(gapShortLabel(weeks: weeks))
                .font(.system(size: max(9, cellSize * 0.55), weight: .medium))
                .foregroundStyle(.secondary)
            Text("no activity")
                .font(.system(size: max(7, cellSize * 0.4)))
                .foregroundStyle(.tertiary)
        }
        .frame(width: gapBlockWidth, height: height)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.18),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
        )
        .help(gapTooltip(weeks: weeks, start: start, end: end))
    }

    // MARK: - Aggregation

    private func computeGrid() -> [[DayCell]] {
        let calendar = Calendar.current
        guard let totals = bucketByDay() else { return [] }

        // End at end of today; start "weeks" ago aligned to start-of-week.
        let endOfToday = calendar.startOfDay(for: Date()).addingTimeInterval(86_399)
        let weeks = range.weeks ?? max(12, weeksSpanned(by: totals, from: endOfToday))
        let approxStart = calendar.date(byAdding: .day, value: -7 * (weeks - 1) + 1, to: endOfToday)
            ?? endOfToday
        let firstDay = calendar.startOfDay(for: approxStart)
        // Align to the previous Sunday so each column is a full week.
        let weekday = calendar.component(.weekday, from: firstDay) // 1 = Sunday
        let columnStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: firstDay)
            ?? firstDay

        var columns: [[DayCell]] = []
        var cursor = columnStart
        while cursor <= endOfToday {
            var column: [DayCell] = []
            for _ in 0..<7 {
                let key = calendar.startOfDay(for: cursor)
                let bucket = totals[key] ?? (count: 0, net: 0.0)
                column.append(DayCell(date: key, count: bucket.count, net: bucket.net))
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            columns.append(column)
        }
        return columns
    }

    private func bucketByDay() -> [Date: (count: Int, net: Double)]? {
        let calendar = Calendar.current
        var buckets: [Date: (count: Int, net: Double)] = [:]
        for tx in state.syncedTransactions {
            guard let date = parseDate(tx.rawDate) else { continue }
            let day = calendar.startOfDay(for: date)
            let amount = Double(tx.principalAmount ?? "") ?? 0
            let signed = tx.rawMessageDirection == "OUTGOING" ? -amount : amount
            buckets[day, default: (0, 0)].count += 1
            buckets[day]?.net += signed
        }
        return buckets.isEmpty ? nil : buckets
    }

    private func weeksSpanned(by buckets: [Date: (count: Int, net: Double)], from end: Date) -> Int {
        guard let oldest = buckets.keys.min() else { return 12 }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: end).day ?? 0
        return max(1, Int(ceil(Double(days) / 7.0)))
    }

    // MARK: - Subviews

    private let minCellSize: CGFloat = 10
    private let maxCellSize: CGFloat = 32
    private let cellSpacing: CGFloat = 4
    /// Runs of at least this many fully empty weeks get collapsed into a slim
    /// "no activity" block so big gaps in the user's history don't squeeze the
    /// active periods to invisibility.
    private let gapWeekThreshold: Int = 4
    private let gapBlockWidth: CGFloat = 60

    private enum Segment: Identifiable {
        case active(columns: [[DayCell]])
        case gap(weeks: Int, start: Date, end: Date)

        var id: String {
            switch self {
            case .active(let cols):
                let first = cols.first?.first?.date.timeIntervalSince1970 ?? 0
                let last  = cols.last?.last?.date.timeIntervalSince1970 ?? 0
                return "a-\(first)-\(last)"
            case .gap(let w, let s, let e):
                return "g-\(w)-\(s.timeIntervalSince1970)-\(e.timeIntervalSince1970)"
            }
        }

        var activeWeekCount: Int {
            if case .active(let cols) = self { return cols.count } else { return 0 }
        }
    }

    private func segmentGrid(_ grid: [[DayCell]]) -> [Segment] {
        var segments: [Segment] = []
        var active: [[DayCell]] = []
        var emptyRun: [[DayCell]] = []

        func flushEmpty() {
            guard !emptyRun.isEmpty else { return }
            if emptyRun.count >= gapWeekThreshold {
                if !active.isEmpty {
                    segments.append(.active(columns: active))
                    active = []
                }
                let start = emptyRun.first!.first!.date
                let end = emptyRun.last!.last!.date
                segments.append(.gap(weeks: emptyRun.count, start: start, end: end))
            } else {
                active.append(contentsOf: emptyRun)
            }
            emptyRun = []
        }

        for col in grid {
            let isEmpty = col.allSatisfy { $0.count == 0 }
            if isEmpty {
                emptyRun.append(col)
            } else {
                flushEmpty()
                active.append(col)
            }
        }
        flushEmpty()
        if !active.isEmpty {
            segments.append(.active(columns: active))
        }
        return segments
    }

    private func gapShortLabel(weeks: Int) -> String {
        if weeks >= 52 {
            let years = weeks / 52
            return "\(years) yr"
        }
        if weeks >= 8 {
            let months = max(1, Int((Double(weeks) / 4.33).rounded()))
            return "\(months) mo"
        }
        return "\(weeks) wk"
    }

    private func gapTooltip(weeks: Int, start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return "No activity · \(weeks) weeks · \(f.string(from: start)) → \(f.string(from: end))"
    }

    @ViewBuilder private func dayOfWeekColumn(cellSize: CGFloat) -> some View {
        let labels = ["S", "M", "T", "W", "T", "F", "S"]
        VStack(spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { i in
                Text(labels[i])
                    .font(.system(size: max(8, cellSize * 0.5), weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: cellSize, height: cellSize)
            }
        }
    }

    @ViewBuilder
    private func gridView(_ grid: [[DayCell]], maxCount: Int, cellSize: CGFloat) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        HStack(spacing: cellSpacing) {
            ForEach(grid.indices, id: \.self) { col in
                VStack(spacing: cellSpacing) {
                    ForEach(grid[col], id: \.id) { cell in
                        cellView(cell, maxCount: maxCount, isFuture: cell.date > today, cellSize: cellSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: DayCell, maxCount: Int, isFuture: Bool, cellSize: CGFloat) -> some View {
        let bucket = intensityBucket(count: cell.count, max: maxCount)
        let isSelected = state.appliedDayFilter
            .map { Calendar.current.isDate($0, inSameDayAs: cell.date) } ?? false
        let cornerRadius = max(2, cellSize * 0.18)
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(isFuture ? Color.clear : bucketColor(bucket))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .help(tooltip(for: cell))
            .onTapGesture {
                guard !isFuture, cell.count > 0 else { return }
                state.appliedDayFilter = cell.date
                sidebar = Sidebar.synced.rawValue
            }
    }

    @ViewBuilder
    private func legend(maxCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Less")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { bucket in
                RoundedRectangle(cornerRadius: 3)
                    .fill(bucketColor(bucket))
                    .frame(width: 12, height: 12)
            }
            Text("More")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if maxCount > 0 {
                Text("Busiest day: \(maxCount) transaction\(maxCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No data yet")
                .foregroundStyle(.secondary)
            Text("Sync some transactions first; the heatmap aggregates the synced data on the Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Helpers

    private func intensityBucket(count: Int, max: Int) -> Int {
        guard count > 0, max > 0 else { return 0 }
        // Logarithmic scale → discrete 5-step palette (idx 1..4 used; 0 reserved for empty).
        let normalized = log2(Double(count) + 1) / log2(Double(max) + 1)
        return Swift.max(1, Swift.min(4, Int(ceil(normalized * 4))))
    }

    private func bucketColor(_ bucket: Int) -> Color {
        switch bucket {
        case 0: return Color.secondary.opacity(0.12)
        case 1: return Color.green.opacity(0.30)
        case 2: return Color.green.opacity(0.55)
        case 3: return Color.green.opacity(0.80)
        default: return Color.green
        }
    }

    private func tooltip(for cell: DayCell) -> String {
        let day = cell.date.formatted(date: .abbreviated, time: .omitted)
        if cell.count == 0 { return "\(day) — no activity" }
        let netSign = cell.net > 0 ? "+" : (cell.net < 0 ? "−" : "")
        let netStr = String(format: "%@%.0f", netSign, abs(cell.net))
        return "\(day) — \(cell.count) tx · net \(netStr)"
    }

    private func parseDate(_ raw: String) -> Date? {
        if let ms = Int64(raw) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
