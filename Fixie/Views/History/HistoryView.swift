// Views/History/HistoryView.swift
import SwiftUI

// MARK: – Filter mode

private enum HistoryFilter: String, CaseIterable {
    case byCategory = "Category"
    case byDate     = "Date"
}

// MARK: – Project model (groups repeat sessions for the same device)

private struct RepairProject: Identifiable {
    let id: String                          // composite key: "category_deviceName"
    let category: RepairCategory
    let entries: [RepairHistoryEntry]       // sorted by date descending

    var latestEntry: RepairHistoryEntry { entries[0] }
    var isMultiSession: Bool { entries.count > 1 }

    /// The device name: subtitle if non-empty, else falls back to title.
    var deviceName: String {
        let s = entries[0].subtitle
        return s.isEmpty ? entries[0].title : s
    }
}

struct HistoryView: View {
    @State private var store          = RepairHistoryStore.shared
    @State private var searchText     = ""
    @State private var filter:  HistoryFilter       = .byCategory
    @State private var catFilter: RepairCategory?   = nil   // nil = all categories
    @State private var selectedEntry: RepairHistoryEntry?

    private var isSignedIn: Bool { AuthService.shared.isSignedIn }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0x0D0D0F).ignoresSafeArea()
                if isSignedIn {
                    VStack(spacing: 0) {
                        filterBar
                        content
                    }
                } else {
                    signedOutState
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Search repairs")
            .sheet(item: $selectedEntry) { entry in
                HistoryDetailView(entry: entry)
            }
        }
    }

    private var signedOutState: some View {
        VStack(spacing: Theme.spacingM) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textTertiary)
            Text("Sign in to see your history")
                .font(Theme.titleMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("Your repair history will appear here once you're signed in.")
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingXL)
            Spacer()
        }
    }

    // MARK: – Filter bar

    private var filterBar: some View {
        VStack(spacing: Theme.spacingS) {
            // Date / Category segmented toggle
            Picker("View by", selection: $filter) {
                ForEach(HistoryFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.spacingM)

            // Category chips (only in category mode)
            if filter == .byCategory {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.spacingS) {
                        // "All" chip
                        FilterChip(
                            label: "All",
                            icon: "square.grid.2x2",
                            isSelected: catFilter == nil,
                            color: Theme.brandPrimary
                        ) { catFilter = nil }

                        ForEach(RepairCategory.allCases) { cat in
                            FilterChip(
                                label: cat.rawValue,
                                icon: cat.icon,
                                isSelected: catFilter == cat,
                                color: cat.accentColor
                            ) {
                                catFilter = (catFilter == cat) ? nil : cat
                            }
                        }
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingXS)
                }
            }
        }
        .padding(.vertical, Theme.spacingS)
        .background(.ultraThinMaterial)
    }

    // MARK: – Content

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            emptyState
        } else if filter == .byCategory {
            categoryList
        } else {
            dateList
        }
    }

    // MARK: – Category-grouped list (with project foldering)

    private var categoryList: some View {
        List {
            ForEach(categorySections, id: \.0) { category, projects in
                Section {
                    ForEach(projects) { project in
                        if project.isMultiSession {
                            ProjectGroupRow(
                                project: project,
                                onSelect:  { selectedEntry = $0 },
                                onDelete:  { store.delete(entry: $0) }
                            )
                        } else {
                            HistoryRowView(entry: project.latestEntry)
                                .onTapGesture { selectedEntry = project.latestEntry }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.delete(entry: project.latestEntry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.06))
                                .listRowSeparatorTint(.white.opacity(0.08))
                        }
                    }
                } header: {
                    CategorySectionHeader(category: category)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: – Date-grouped list

    private var dateList: some View {
        List {
            ForEach(dateSections, id: \.0) { title, entries in
                Section(title) {
                    ForEach(entries) { entry in
                        HistoryRowView(entry: entry)
                            .onTapGesture { selectedEntry = entry }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(entry: entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                            .listRowSeparatorTint(.white.opacity(0.08))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: – Filtered entries

    private var filteredEntries: [RepairHistoryEntry] {
        var result = store.entries
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.subtitle.localizedCaseInsensitiveContains(searchText) ||
                $0.symptom.localizedCaseInsensitiveContains(searchText)
            }
        }
        if let cat = catFilter {
            result = result.filter { $0.category == cat }
        }
        return result
    }

    // MARK: – Category sections (with project grouping)

    private var categorySections: [(RepairCategory, [RepairProject])] {
        // Bucket entries by category
        var buckets: [RepairCategory: [RepairHistoryEntry]] = [:]
        for entry in filteredEntries {
            buckets[entry.category, default: []].append(entry)
        }

        return RepairCategory.allCases.compactMap { cat in
            guard let catEntries = buckets[cat], !catEntries.isEmpty else { return nil }

            // Within the category, group by device name (subtitle ?? title)
            var deviceBuckets: [String: [RepairHistoryEntry]] = [:]
            for entry in catEntries {
                let key = entry.subtitle.isEmpty ? entry.title : entry.subtitle
                deviceBuckets[key, default: []].append(entry)
            }

            let projects = deviceBuckets
                .map { key, deviceEntries in
                    RepairProject(
                        id:       "\(cat.rawValue)_\(key)",
                        category: cat,
                        entries:  deviceEntries.sorted { $0.date > $1.date }
                    )
                }
                .sorted { $0.latestEntry.date > $1.latestEntry.date }

            return (cat, projects)
        }
    }

    // MARK: – Date sections

    private var dateSections: [(String, [RepairHistoryEntry])] {
        let cal = Calendar.current
        let now = Date.now
        var today: [RepairHistoryEntry]    = []
        var thisWeek: [RepairHistoryEntry] = []
        var earlier: [RepairHistoryEntry]  = []

        for entry in filteredEntries {
            if cal.isDateInToday(entry.date) {
                today.append(entry)
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
                      entry.date > weekAgo {
                thisWeek.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var sections: [(String, [RepairHistoryEntry])] = []
        if !today.isEmpty    { sections.append(("Today",     today))     }
        if !thisWeek.isEmpty { sections.append(("This Week", thisWeek))  }
        if !earlier.isEmpty  { sections.append(("Earlier",   earlier))   }
        return sections
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textTertiary)
            Text("No repairs yet")
                .font(Theme.titleMedium)
                .foregroundStyle(Theme.textTertiary)
            Text("Complete a repair to see your history here.")
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: – Project group row (DisclosureGroup for multi-session devices)

private struct ProjectGroupRow: View {
    let project: RepairProject
    let onSelect: (RepairHistoryEntry) -> Void
    let onDelete: (RepairHistoryEntry) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(project.entries) { entry in
                HistoryRowView(entry: entry)
                    .onTapGesture { onSelect(entry) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { onDelete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                    .listRowSeparatorTint(.white.opacity(0.06))
                    .padding(.leading, Theme.spacingS)
            }
        } label: {
            projectLabel
        }
        .listRowBackground(Color.white.opacity(0.06))
        .listRowSeparatorTint(.white.opacity(0.08))
    }

    private var projectLabel: some View {
        HStack(spacing: Theme.spacingM) {
            // Category icon with session-count badge
            ZStack(alignment: .topTrailing) {
                Image(systemName: project.category.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(project.category.accentColor)
                    .frame(width: 44, height: 44)
                    .background(project.category.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                Text("\(project.entries.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 16, height: 16)
                    .background(project.category.accentColor, in: Circle())
                    .offset(x: 4, y: -4)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("PROJECT · \(project.entries.count) SESSIONS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(project.deviceName)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(project.latestEntry.date, style: .relative)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: – Category section header

private struct CategorySectionHeader: View {
    let category: RepairCategory

    var body: some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: category.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(category.accentColor)
                .frame(width: 26, height: 26)
                .background(category.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            Text(category.rawValue)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(category.accentColor)
        }
        .padding(.vertical, 2)
    }
}

// MARK: – Filter chip

private struct FilterChip: View {
    let label:      String
    let icon:       String
    let isSelected: Bool
    let color:      Color
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .black : color)
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.12)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isSelected)
    }
}

// MARK: – Row

private struct HistoryRowView: View {
    let entry: RepairHistoryEntry

    // Lazily fetched logo for older entries saved before the logo fix
    @State private var fetchedLogoUrl: String = ""

    private var effectiveLogoUrl: String {
        !entry.proLogoUrl.isEmpty ? entry.proLogoUrl : fetchedLogoUrl
    }

    private var categoryIcon: some View {
        Image(systemName: entry.category.icon)
            .font(.system(size: 22))
            .foregroundStyle(entry.category.accentColor)
            .frame(width: 44, height: 44)
            .background(entry.category.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            ZStack(alignment: .bottomTrailing) {
                if !effectiveLogoUrl.isEmpty, let logoURL = URL(string: effectiveLogoUrl) {
                    // Contractor-resolved: show business logo
                    AsyncImage(url: logoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable()
                               .scaledToFill()
                               .frame(width: 44, height: 44)
                               .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            categoryIcon
                        }
                    }
                } else if let data = entry.thumbnailData, let img = UIImage(data: data) {
                    // DIY repair: show captured photo thumbnail
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if !entry.thumbnailUrl.isEmpty, let url = URL(string: entry.thumbnailUrl) {
                    // Contractor-resolved with no logo: show lead photo
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable()
                               .scaledToFill()
                               .frame(width: 44, height: 44)
                               .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            categoryIcon
                        }
                    }
                } else {
                    categoryIcon
                }
                Circle()
                    .fill(entry.isCompleted ? Theme.brandSecondary : Theme.warningAmber)
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                // Contractor attribution badge
                if entry.proName != nil {
                    let displayName = entry.assignedTechName.isEmpty
                        ? (entry.proName ?? "")
                        : entry.assignedTechName
                    HStack(spacing: 4) {
                        Image(systemName: "person.badge.shield.checkmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Fixed by \(displayName)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Theme.brandSecondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if entry.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.brandSecondary)
                } else {
                    Text("\(entry.completionPercent)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.warningAmber)
                }
                Text(entry.date, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
        // Backfill logo for older entries saved before logo was stored
        .task(id: entry.leadId) {
            guard entry.proLogoUrl.isEmpty,
                  entry.proName != nil,
                  !entry.leadId.isEmpty else { return }
            // Fetch proId from the lead doc, then logo from contractors
            if let data = await FirebaseService.shared.fetchResolvedLead(entry.leadId),
               let proId = data["proId"] as? String, !proId.isEmpty {
                let url = await FirebaseService.shared.fetchContractorLogoUrl(proId: proId)
                if !url.isEmpty {
                    fetchedLogoUrl = url
                    // Persist so we don't fetch again next time
                    entry.proLogoUrl = url
                    RepairHistoryStore.shared.loadEntries()
                }
            }
        }
    }
}

// MARK: – Detail sheet

struct HistoryDetailView: View {
    let entry: RepairHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showReviewSheet = false
    @State private var resolvedProId: String = ""
    @State private var invoices: [Invoice] = []
    @State private var invoicesLoaded = false
    @State private var invoiceToShare: [Any]? = nil
    @State private var showShareSheet = false
    @State private var showInvoiceViewer = false

    private var effectiveProId: String {
        !entry.proId.isEmpty ? entry.proId : resolvedProId
    }

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.spacingL) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(Theme.titleMedium)
                                .foregroundStyle(Theme.textPrimary)
                            if !entry.subtitle.isEmpty {
                                Text(entry.subtitle)
                                    .font(Theme.bodyRegular)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let data = entry.thumbnailData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
                    } else if !entry.thumbnailUrl.isEmpty, let url = URL(string: entry.thumbnailUrl) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable()
                                   .scaledToFill()
                                   .frame(height: 200)
                                   .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
                            }
                        }
                    }

                    infoCard(label: "Symptom", value: entry.symptom)

                    // Contractor attribution card
                    if entry.proName != nil {
                        let techDisplay = entry.assignedTechName.isEmpty
                            ? (entry.proName ?? "")
                            : entry.assignedTechName
                        VStack(alignment: .leading, spacing: Theme.spacingS) {
                            HStack(spacing: Theme.spacingM) {
                                Image(systemName: "person.badge.shield.checkmark.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.brandSecondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Fixed by Contractor")
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(techDisplay)
                                        .font(Theme.bodyBold)
                                        .foregroundStyle(Theme.brandSecondary)
                                    if !entry.proBusinessName.isEmpty {
                                        Text(entry.proBusinessName)
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    if let phone = entry.proPhone {
                                        Link(phone, destination: URL(string: "tel://\(phone.filter(\.isNumber))")!)
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.brandPrimary)
                                    }
                                }
                                Spacer()
                            }

                            if !entry.resolutionNotes.isEmpty {
                                Divider().background(.white.opacity(0.1))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("What Was Done")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(entry.resolutionNotes)
                                        .font(Theme.bodyRegular)
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }

                            // Leave a review (shown if not yet reviewed and proId is known)
                            if !entry.hasReviewed && !effectiveProId.isEmpty {
                                Divider().background(.white.opacity(0.1))
                                Button { showReviewSheet = true } label: {
                                    HStack(spacing: Theme.spacingS) {
                                        Image(systemName: "star.bubble.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.brandSecondary)
                                        Text("Leave a Review")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Theme.brandSecondary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.top, Theme.spacingXS)
                                }
                                .buttonStyle(.plain)
                            } else if entry.hasReviewed {
                                Divider().background(.white.opacity(0.1))
                                Label("Review Submitted", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.brandSecondary.opacity(0.7))
                                    .padding(.top, Theme.spacingXS)
                            }
                        }
                        .padding(Theme.spacingM)
                        .background(Theme.brandSecondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                            .strokeBorder(Theme.brandSecondary.opacity(0.25), lineWidth: 1))
                    }

                    // Invoice card (contractor repairs only)
                    if entry.proName != nil && !entry.leadId.isEmpty {
                        invoiceCard
                    }

                    VStack(alignment: .leading, spacing: Theme.spacingS) {
                        Text("Progress")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                        ProgressView(
                            value:  Double(entry.stepsCompleted),
                            total:  Double(max(entry.stepsTotal, 1))
                        )
                        .tint(entry.isCompleted ? Theme.brandSecondary : Theme.brandPrimary)
                        Text("\(entry.stepsCompleted) of \(entry.stepsTotal) steps complete")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.spacingM)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))

                    infoCard(label: "Date",
                             value: entry.date.formatted(date: .long, time: .shortened))

                    Spacer(minLength: Theme.spacingXL)
                }
                .padding(Theme.spacingM)
            }
        }
        .sheet(isPresented: $showReviewSheet) {
            ContractorReviewSheet(
                proId:           effectiveProId,
                proName:         entry.proName ?? "",
                proBusinessName: entry.proBusinessName,
                leadId:          entry.leadId,
                deviceModel:     entry.subtitle.isEmpty ? entry.title : entry.subtitle
            ) {
                entry.hasReviewed = true
                RepairHistoryStore.shared.loadEntries()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(hex: 0x0D0D0F))
        }
        .task(id: entry.leadId) {
            guard effectiveProId.isEmpty,
                  entry.proName != nil,
                  !entry.leadId.isEmpty else { return }
            if let data = await FirebaseService.shared.fetchResolvedLead(entry.leadId),
               let proId = data["proId"] as? String, !proId.isEmpty {
                resolvedProId = proId
                entry.proId = proId
                RepairHistoryStore.shared.loadEntries()
            }
        }
        .sheet(isPresented: $showInvoiceViewer) {
            if let urlStr = entry.invoiceUrl.isEmpty ? nil : entry.invoiceUrl,
               let url = URL(string: urlStr) {
                InAppDocumentViewer(url: url, title: "Invoice")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let items = invoiceToShare {
                ShareSheet(activityItems: items)
                    .ignoresSafeArea()
            }
        }
        .task(id: entry.leadId + "_invoices") {
            guard entry.proName != nil, !entry.leadId.isEmpty else { return }
            invoices = await FirebaseService.shared.fetchInvoices(leadId: entry.leadId)
            invoicesLoaded = true
        }
    }

    // MARK: – Invoice card

    @ViewBuilder
    private var invoiceCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingS) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x2979FF))
                Text("Invoice")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !invoicesLoaded {
                    ProgressView().scaleEffect(0.7).tint(Theme.textTertiary)
                }
            }

            // Direct invoice URL — available as soon as the contractor creates the invoice
            if !entry.invoiceUrl.isEmpty {
                Button {
                    showInvoiceViewer = true
                } label: {
                    Label("View Your Invoice", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: 0x2979FF), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            if invoicesLoaded && invoices.isEmpty && entry.invoiceUrl.isEmpty {
                Text("No invoice on file")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            ForEach(invoices) { invoice in
                InvoiceCardView(invoice: invoice)

                HStack(spacing: Theme.spacingS) {
                    // Share / Save to Files — shares the live web invoice URL
                    Button {
                        let id = invoice.jobId.isEmpty ? invoice.id : invoice.jobId
                        if let url = URL(string: "https://fixieai.app/invoice/\(id)") {
                            invoiceToShare = [url]
                            showShareSheet = true
                        }
                    } label: {
                        Label("Save / Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x2979FF))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(hex: 0x2979FF).opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    // Print
                    Button {
                        printInvoice(invoice)
                    } label: {
                        Label("Print", systemImage: "printer")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(Color(hex: 0x2979FF).opacity(0.2), lineWidth: 1))
    }

    private func infoCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.bodyRegular).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
    }

    // Renders the invoice SwiftUI view to a PDF file in the temp directory.
    @MainActor
    private func renderInvoicePDF(_ invoice: Invoice) -> URL {
        let content = InvoiceCardView(invoice: invoice)
            .frame(width: 360)
            .padding(24)
            .background(Color(hex: 0x1A1A1F))
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0   // print-quality resolution

        let name = "Invoice-\(invoice.invoiceNumber.isEmpty ? invoice.id : invoice.invoiceNumber).pdf"
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        renderer.render { size, ctx in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            ctx(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        return url
    }

    private func printInvoice(_ invoice: Invoice) {
        let id  = invoice.jobId.isEmpty ? invoice.id : invoice.jobId
        guard let url = URL(string: "https://fixieai.app/invoice/\(id)") else { return }
        WebInvoicePrinter.shared.startPrint(url: url, jobName: "Invoice \(invoice.invoiceNumber)")
    }
}


// MARK: – Web invoice printer
// WKWebView MUST be in the window hierarchy to receive network access on iOS.
// We attach it hidden, wait for the page to finish loading, then print and remove it.
import WebKit

final class WebInvoicePrinter: NSObject, WKNavigationDelegate {
    static let shared = WebInvoicePrinter()
    private var webView: WKWebView?
    private var jobName = ""

    func startPrint(url: URL, jobName: String) {
        self.jobName = jobName
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        wv.isHidden = true
        wv.navigationDelegate = self
        webView = wv
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        window.addSubview(wv)
        wv.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let ctrl = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        ctrl.printInfo = info
        ctrl.printFormatter = webView.viewPrintFormatter()
        ctrl.present(animated: true) { [weak self] _, _, _ in
            self?.webView?.removeFromSuperview()
            self?.webView = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Swift.print("[Fixie] WebInvoicePrinter failed: \(error.localizedDescription)")
        webView.removeFromSuperview()
        self.webView = nil
    }
}

// MARK: – Share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

