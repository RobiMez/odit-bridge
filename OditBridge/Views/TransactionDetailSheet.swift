import SwiftUI

// Two-column transaction inspector. Left side is read-only context; right side
// is the editable enrichment form (category, reason, mark-internal).
// Lays out in a fixed ~720x560 sheet.
struct TransactionDetailSheet: View {
    let transaction: SyncedTransaction

    @EnvironmentObject var reference: ReferenceData
    @Environment(\.syncService) private var syncService
    @Environment(\.dismiss) private var dismiss

    @State private var draftCategoryId: Int?
    @State private var draftReason: String = ""
    @State private var draftIsInternal: Bool = false

    @State private var saving = false
    @State private var error: String?
    @State private var bodyExpanded = false

    private var changed: Bool {
        draftCategoryId != transaction.categoryId
            || draftReason != (transaction.reason ?? "")
            || draftIsInternal != (transaction.isInternalTransfer ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transaction")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed || saving)
            }
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                readOnly
                    .frame(maxWidth: .infinity)
                    .padding(16)
                Divider()
                editable
                    .frame(width: 300)
                    .padding(16)
            }
            if let error {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 560)
        .onAppear(perform: hydrateDrafts)
    }

    // MARK: - Read-only side

    @ViewBuilder private var readOnly: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                amountBlock
                Divider()
                infoRows
                Divider()
                participantsBlock
                Divider()
                rawBodyBlock
                if let ocr = ocrSummary {
                    Divider()
                    ocrBlock(ocr)
                }
            }
        }
    }

    @ViewBuilder private var amountBlock: some View {
        let outgoing = transaction.rawMessageDirection == "OUTGOING"
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(outgoing ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.amountText ?? "—")
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(outgoing ? .red : .green)
                if let bal = transaction.balanceAfterText {
                    Text(bal)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var infoRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("Type", transaction.messageType?
                .replacingOccurrences(of: "_", with: " ")
                .capitalized ?? "—")
            infoRow("Provider", transaction.rawAddress)
            infoRow("Date", formattedDate)
            if let cur = transaction.principalCurrency {
                infoRow("Currency", cur)
            }
            if let fee = transaction.feeAmount {
                infoRow("Fee", "\(fee) \(transaction.feeCurrency ?? "")")
            }
            if let before = transaction.balanceBeforeAmount {
                infoRow("Balance before", "\(before) \(transaction.balanceBeforeCurrency ?? "")")
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.callout)
        }
    }

    @ViewBuilder private var participantsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants")
                .font(.caption)
                .foregroundStyle(.secondary)
            let participants = transaction.extractionParticipants ?? []
            if participants.isEmpty {
                Text("—").foregroundStyle(.tertiary).font(.callout)
            } else {
                ForEach(participants, id: \.id) { p in
                    HStack(spacing: 6) {
                        Image(systemName: p.role == "SENDER" ? "arrow.right" : "arrow.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(p.displayName).font(.callout)
                        Text("(\(p.role.capitalized))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var rawBodyBlock: some View {
        DisclosureGroup(isExpanded: $bodyExpanded) {
            Text(transaction.rawBody)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        } label: {
            Text("Raw SMS")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ocrSummary: String? {
        // The OCR payload shape varies — we just stringify if present so the
        // user can see something was attached. Receipt upload is out of scope
        // for this landing; this is a read-only display.
        return nil
    }

    @ViewBuilder private func ocrBlock(_ ocr: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Receipt OCR")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ocr)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var formattedDate: String {
        guard let d = SyncedView.parseRawDate(transaction.rawDate) else {
            return transaction.rawDate
        }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Editable side

    @ViewBuilder private var editable: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Category
            VStack(alignment: .leading, spacing: 4) {
                Text("CATEGORY")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if reference.categories.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("", selection: $draftCategoryId) {
                        Text("None").tag(Int?.none)
                        ForEach(reference.categories) { cat in
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: cat.color)).frame(width: 8, height: 8)
                                Text(cat.name)
                            }
                            .tag(Int?(cat.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            // Reason
            VStack(alignment: .leading, spacing: 4) {
                Text("REASON / NOTE")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftReason)
                    .font(.callout)
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // Mark internal
            Toggle(isOn: $draftIsInternal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Internal transfer")
                        .font(.callout)
                    Text("A move between your own accounts; excluded from spending totals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func hydrateDrafts() {
        draftCategoryId = transaction.categoryId
        draftReason = transaction.reason ?? ""
        draftIsInternal = transaction.isInternalTransfer ?? false
    }

    private func save() async {
        guard let svc = syncService else {
            error = "Sync service unavailable."
            return
        }
        saving = true
        defer { saving = false }
        error = nil

        let categoryChanged = draftCategoryId != transaction.categoryId
        let reasonChanged = draftReason != (transaction.reason ?? "")
        let internalChanged = draftIsInternal != (transaction.isInternalTransfer ?? false)

        do {
            if categoryChanged || reasonChanged {
                try await svc.updateTransaction(
                    id: transaction.id,
                    categoryId: draftCategoryId,
                    reason: reasonChanged ? draftReason : transaction.reason
                )
            }
            if internalChanged {
                try await svc.markInternal(id: transaction.id, isInternal: draftIsInternal)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
