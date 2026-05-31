import SwiftUI
import Charts

// Period chips at top + KPI cards + daily-net BarMark + category-spending donut.
//
// KPI numbers come from the server's `/charts/:deviceId/summary-all` endpoint
// (one fetch, all six periods). The chart visualisations are aggregated
// client-side from the synced transactions for the chosen period so they stay
// in sync with what's visible in the Synced table.
struct ChartsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var reference: ReferenceData
    @Environment(\.syncService) private var syncService

    enum Period: String, CaseIterable, Identifiable {
        case day, week, month, quarter, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "Day"
            case .week: return "Week"
            case .month: return "Month"
            case .quarter: return "Qtr"
            case .year: return "Year"
            case .all: return "All"
            }
        }
    }
    @State private var period: Period = .month

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if let summary = reference.chartsSummary,
                   let bucket = summary.periods[period.rawValue] {
                    kpiCards(bucket.combined)
                        .padding(.horizontal, 16)
                } else if reference.summaryLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading summary…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                } else {
                    Text("No summary yet. Pull synced data to populate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                Divider()
                dailyNetFlowChart
                    .padding(.horizontal, 16)

                Divider()
                categoryDonutChart
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .task {
            if reference.providers.isEmpty { await syncService?.fetchProviders() }
            if reference.categories.isEmpty { await syncService?.fetchCategories() }
            if reference.chartsSummary == nil { await syncService?.fetchSummary() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await syncService?.fetchSummary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(reference.summaryLoading)
            }
        }
    }

    // MARK: - KPI cards

    @ViewBuilder
    private func kpiCards(_ c: ChartsCombined) -> some View {
        HStack(spacing: 10) {
            kpi("Net", c.net, accent: c.net >= 0 ? .green : .red)
            kpi("Incoming", c.totalIncoming, accent: .green)
            kpi("Outgoing", c.totalOutgoing, accent: .red)
            kpi("Fees", c.totalFees, accent: .orange)
            kpiCount("Transactions", c.totalTransactions)
        }
    }

    @ViewBuilder
    private func kpi(_ label: String, _ value: Double, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(formatCurrency(value))
                .font(.title3.weight(.semibold))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func kpiCount(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Daily net flow

    @ViewBuilder
    private var dailyNetFlowChart: some View {
        let buckets = dailyBuckets()
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily net flow")
                .font(.headline)
            if buckets.isEmpty {
                Text("No transactions in this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
            } else {
                Chart(buckets) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Net", day.net)
                    )
                    .foregroundStyle(day.net >= 0 ? Color.green : Color.red)
                }
                .frame(height: 220)
            }
        }
    }

    // MARK: - Category donut

    @ViewBuilder
    private var categoryDonutChart: some View {
        let slices = categorySlices()
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by category")
                .font(.headline)
            if slices.isEmpty {
                Text("No outgoing transactions in this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("Amount", slice.amount),
                            innerRadius: .ratio(0.6),
                            angularInset: 1
                        )
                        .foregroundStyle(slice.color)
                    }
                    .frame(width: 220, height: 220)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices) { slice in
                            HStack(spacing: 8) {
                                Circle().fill(slice.color).frame(width: 10, height: 10)
                                Text(slice.name).font(.callout)
                                Spacer()
                                Text(formatCurrency(slice.amount))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Aggregations

    private struct DayBucket: Identifiable {
        let date: Date
        let net: Double
        var id: Date { date }
    }

    private struct CategorySlice: Identifiable {
        let id: Int
        let name: String
        let amount: Double
        let color: Color
    }

    private func dailyBuckets() -> [DayBucket] {
        let (start, end) = periodBounds()
        let calendar = Calendar.current
        var byDay: [Date: Double] = [:]
        for tx in state.syncedTransactions {
            guard let date = SyncedView.parseRawDate(tx.rawDate) else { continue }
            if date < start || date > end { continue }
            let amount = Double(tx.principalAmount ?? "") ?? 0
            let signed = tx.rawMessageDirection == "OUTGOING" ? -amount : amount
            let day = calendar.startOfDay(for: date)
            byDay[day, default: 0] += signed
        }
        return byDay.map { DayBucket(date: $0.key, net: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private func categorySlices() -> [CategorySlice] {
        let (start, end) = periodBounds()
        var byCategory: [Int: Double] = [:]
        var uncategorised: Double = 0
        for tx in state.syncedTransactions {
            guard let date = SyncedView.parseRawDate(tx.rawDate) else { continue }
            if date < start || date > end { continue }
            guard tx.rawMessageDirection == "OUTGOING" else { continue }
            let amount = Double(tx.principalAmount ?? "") ?? 0
            if let cid = tx.categoryId {
                byCategory[cid, default: 0] += amount
            } else {
                uncategorised += amount
            }
        }
        let total = byCategory.values.reduce(0, +) + uncategorised
        guard total > 0 else { return [] }

        var slices: [CategorySlice] = byCategory.compactMap { (cid, amount) in
            guard let cat = reference.category(forId: cid) else {
                return CategorySlice(id: cid, name: "Category \(cid)",
                                     amount: amount, color: .gray)
            }
            return CategorySlice(id: cid, name: cat.name, amount: amount,
                                 color: Color(hex: cat.color))
        }
        slices.sort { $0.amount > $1.amount }
        if uncategorised > 0 {
            slices.append(CategorySlice(id: -1, name: "Uncategorised",
                                        amount: uncategorised,
                                        color: Color.gray.opacity(0.35)))
        }
        return slices
    }

    private func periodBounds() -> (Date, Date) {
        // Prefer server-provided period bounds (timezone-aware).
        if let bounds = reference.chartsSummary?.periods[period.rawValue]?.period {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let s = iso.date(from: bounds.startDate),
               let e = iso.date(from: bounds.endDate) {
                return (s, e)
            }
            iso.formatOptions = [.withInternetDateTime]
            if let s = iso.date(from: bounds.startDate),
               let e = iso.date(from: bounds.endDate) {
                return (s, e)
            }
        }
        // Fallback: compute locally.
        let now = Date()
        let calendar = Calendar.current
        let start: Date
        switch period {
        case .day:     start = calendar.startOfDay(for: now)
        case .week:    start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:   start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .quarter: start = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .year:    start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:     start = .distantPast
        }
        return (start, now)
    }

    private func formatCurrency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
