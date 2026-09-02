//
//  CupboardViews.swift
//  Agentic
//

import PhotosUI
import SwiftUI
import UIKit

/// The bags the user owns. Separate from the chat because a list you scan,
/// correct and delete is direct manipulation, not something to ask an agent
/// for; the agent reads the same bags through `Cupboard`.
struct CupboardView: View {
    let manager: CupboardManager
    @Environment(\.dismiss) private var dismiss
    @State private var entry: EntryRoute?

    private enum EntryRoute: Identifiable {
        case scan
        case manual

        var id: String { self == .scan ? "scan" : "manual" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Cupboard").font(Theme.display).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Scan the bag", systemImage: "camera") { entry = .scan }
                        Button("Enter by hand", systemImage: "square.and.pencil") { entry = .manual }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                }
            }
            .sheet(item: $entry) { route in
                switch route {
                case .scan:
                    ScanFlowView(manager: manager)
                case .manual:
                    NavigationStack {
                        BagDraftForm(manager: manager, draft: BagScanner.Draft(), ocrText: nil) {
                            entry = nil
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            Text("No bags yet.").font(Theme.display).foregroundStyle(Theme.ink)
            Text("Scan a label and the fields come off the packaging. Everything the agent says about what you own reads from here.")
                .font(Theme.control)
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(Theme.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        List {
            ForEach(manager.beans) { bean in
                NavigationLink {
                    BeanDetailView(manager: manager, bean: bean)
                } label: {
                    BagRow(bean: bean, brews: manager.sessions(for: bean).count)
                }
                .listRowBackground(Theme.paper)
            }
            .onDelete { offsets in
                offsets.map { manager.beans[$0] }.forEach(manager.delete)
            }
        }
        .listStyle(.plain)
    }
}

private struct BagRow: View {
    let bean: OwnedBean
    let brews: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.xs) {
            HStack(spacing: Theme.sm) {
                Text(bean.displayName).font(Theme.reading).foregroundStyle(Theme.ink)
                if bean.scanConfidence == .scanUnverified {
                    Text("unconfirmed")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.danger)
                }
            }
            Text(detail).font(Theme.label).foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, Theme.xs)
    }

    private var detail: String {
        var parts: [String] = []
        if let roaster = bean.roasterName { parts.append(roaster) }
        if let days = bean.daysSinceRoast { parts.append("roasted \(days)d ago") }
        if let grams = bean.remainingGrams { parts.append("\(grams)g left") }
        parts.append(brews == 1 ? "1 brew" : "\(brews) brews")
        return parts.joined(separator: " · ")
    }
}

struct BeanDetailView: View {
    let manager: CupboardManager
    let bean: OwnedBean

    var body: some View {
        List {
            Section {
                LabelledRow("Roaster", bean.roasterName)
                LabelledRow("Origin", [bean.subregion, bean.island?.label].compactMap { $0 }.joined(separator: ", "))
                LabelledRow("Process", bean.processingMethod?.label)
                LabelledRow("Roast", bean.roastLevel?.label ?? "Not recorded")
                LabelledRow("Roasted", bean.roastDate?.formatted(date: .abbreviated, time: .omitted))
                LabelledRow("Bag", bean.bagWeightGrams.map { "\($0)g" })
                LabelledRow("Provenance", bean.scanConfidence.label)
            }
            .listRowBackground(Theme.paper)

            Section("Next grind") {
                Text(manager.grindAdvice(for: bean).message)
                    .font(Theme.reading)
                    .foregroundStyle(Theme.ink)
            }
            .listRowBackground(Theme.paper)

            Section("Brews") {
                let sessions = manager.sessions(for: bean)
                if sessions.isEmpty {
                    Text("None logged yet.").font(Theme.control).foregroundStyle(Theme.inkMuted)
                } else {
                    ForEach(sessions) { session in
                        BrewRow(session: session)
                    }
                }
            }
            .listRowBackground(Theme.paper)
        }
        .listStyle(.plain)
        .background(Theme.paper)
        .navigationTitle(bean.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
    }
}

private struct BrewRow: View {
    let session: BrewSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.xs) {
            Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · grind \(session.grindSetting.isEmpty ? "unrecorded" : session.grindSetting)")
                .font(Theme.control)
                .foregroundStyle(Theme.ink)
            Text(timings).font(Theme.trace).foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, Theme.xs)
    }

    private var timings: String {
        var parts: [String] = []
        if let drip = session.timeToFirstDripSeconds { parts.append("first drip \(drip)s") }
        if let total = session.totalSeconds { parts.append("total \(total)s") }
        if let outcome = session.outcome {
            parts.append(outcome.symptom?.label ?? "rated \(outcome.rating)/5")
        } else {
            parts.append("not rated")
        }
        return parts.joined(separator: " · ")
    }
}

private struct LabelledRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = (value?.isEmpty ?? true) ? nil : value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkMuted)
            Spacer(minLength: Theme.md)
            Text(value ?? "Not recorded")
                .font(Theme.control)
                .foregroundStyle(value == nil ? Theme.inkMuted : Theme.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: Adding a bag

/// The confirm step the scan pipeline requires, and the whole of the manual
/// path. Coffee bags are matte, curved and often dark on dark, so OCR will
/// misread; nothing reaches the store without passing through here.
///
/// Carries no `NavigationStack` and calls `onFinish` rather than `dismiss()`,
/// so it can be presented as a sheet on the manual path and shown inline on
/// the scan path. That is what keeps the scan flow to a single presentation:
/// pushing this as a second sheet from a view that was itself still settling
/// is what produced "whose view is not in the window hierarchy".
struct BagDraftForm: View {
    let manager: CupboardManager
    @State var draft: BagScanner.Draft
    let ocrText: String?
    let onFinish: () -> Void

    @State private var hasRoastDate: Bool

    init(manager: CupboardManager, draft: BagScanner.Draft, ocrText: String?, onFinish: @escaping () -> Void) {
        self.manager = manager
        self._draft = State(initialValue: draft)
        self.ocrText = ocrText
        self.onFinish = onFinish
        self._hasRoastDate = State(initialValue: draft.roastDate != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.displayName)
                TextField("Roaster", text: $draft.roasterName)
                TextField("Region", text: $draft.subregion)
            }
            .listRowBackground(Theme.paperRaised)

            Section {
                Picker("Island", selection: $draft.island) {
                    Text("Not stated").tag(Island?.none)
                    ForEach(Island.allCases, id: \.self) { Text($0.label).tag(Island?.some($0)) }
                }
                Picker("Process", selection: $draft.processingMethod) {
                    Text("Not stated").tag(ProcessingMethod?.none)
                    ForEach(ProcessingMethod.allCases, id: \.self) { Text($0.label).tag(ProcessingMethod?.some($0)) }
                }
                Picker("Roast", selection: $draft.roastLevel) {
                    Text("Not stated").tag(RoastLevel?.none)
                    ForEach(RoastLevel.allCases, id: \.self) { Text($0.label).tag(RoastLevel?.some($0)) }
                }
            }
            .listRowBackground(Theme.paperRaised)

            Section {
                Toggle("Roast date on the bag", isOn: $hasRoastDate)
                if hasRoastDate {
                    DatePicker(
                        "Roasted",
                        selection: Binding(get: { draft.roastDate ?? .now }, set: { draft.roastDate = $0 }),
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                }
                TextField("Bag weight in grams", value: $draft.weightGrams, format: .number)
                    .keyboardType(.numberPad)
            }
            .listRowBackground(Theme.paperRaised)

            if let ocrText {
                Section("What the scan read") {
                    Text(ocrText).font(Theme.trace).foregroundStyle(Theme.inkMuted)
                }
                .listRowBackground(Theme.paperRaised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ocrText == nil ? "New bag" : "Check the scan")
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinish() }.tint(Theme.inkMuted)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .tint(Theme.accent)
                    .disabled(!draft.isSaveable)
            }
        }
    }

    /// Confirming is what promotes a scan from unverified to checked, which is
    /// the only signal downstream has that a human looked at these fields.
    private func save() {
        Log.write(.ui, "bag confirmed by hand, promoting \(draft.scanConfidence.rawValue)")
        var confirmed = draft
        if !hasRoastDate { confirmed.roastDate = nil }
        if confirmed.scanConfidence == .scanUnverified { confirmed.scanConfidence = .scanConfirmed }
        manager.add(confirmed)
        onFinish()
    }
}

/// Capture, read, extract, confirm. The confirm step is mandatory, so this
/// view never writes to the store itself: it swaps its own content for
/// `BagDraftForm` once a draft exists.
struct ScanFlowView: View {
    let manager: CupboardManager

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var stage = Stage.capture
    @State private var ocrText: String?
    @State private var draft: BagScanner.Draft?
    @State private var failure: String?
    @State private var showingCamera = false
    @State private var pendingImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?

    private enum Stage { case capture, reading, extracting, ready }

    var body: some View {
        NavigationStack {
            if let draft {
                BagDraftForm(manager: manager, draft: draft, ocrText: ocrText) { dismiss() }
            } else {
                capture
            }
        }
    }

    private var capture: some View {
    VStack(alignment: .leading, spacing: Theme.lg) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(.rect(cornerRadius: Theme.bubbleRadius))
            }

            switch stage {
            case .capture:
                Text("Photograph the label straight on, filling the frame. Matte and curved bags read badly, so you will get a chance to correct every field.")
                    .font(Theme.control)
                    .foregroundStyle(Theme.inkMuted)

                Button("Take a photo") { showingCamera = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                PhotosPicker("Choose from library", selection: $pickerItem, matching: .images)
                    .tint(Theme.accent)

            case .reading, .extracting:
                HStack(spacing: Theme.sm) {
                    ProgressView().controlSize(.small)
                    Text(stage == .reading ? "Reading the label" : "Pulling out the fields")
                        .font(Theme.control)
                        .foregroundStyle(Theme.inkMuted)
                }

            case .ready:
                EmptyView()
            }

            if let ocrText, stage != .capture {
                Text(ocrText).font(Theme.trace).foregroundStyle(Theme.inkMuted)
            }

            if let failure {
                Text(failure).font(Theme.trace).foregroundStyle(Theme.danger)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Scan a bag").font(Theme.display).foregroundStyle(Theme.ink)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.tint(Theme.inkMuted)
            }
        }
        // Processing waits for the camera to finish dismissing. Starting it
        // from `onCapture` sets `draft` while the cover is still on screen,
        // and the confirm sheet then tries to present from a view that is
        // no longer in the window hierarchy.
        .fullScreenCover(isPresented: $showingCamera, onDismiss: processPendingCapture) {
            CameraPicker { captured in
                image = captured
                pendingImage = captured
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                guard
                    let data = try? await pickerItem.loadTransferable(type: Data.self),
                    let loaded = UIImage(data: data)
                else {
                    Log.write(.failure, "photo library item could not be loaded")
                    failure = "That image could not be loaded."
                    return
                }
                image = loaded
                await process(loaded)
            }
        }
    }

    private func processPendingCapture() {
        guard let pendingImage else { return }
        self.pendingImage = nil
        Task { await process(pendingImage) }
    }

    private func process(_ captured: UIImage) async {
        guard let cgImage = captured.cgImage else {
            failure = "That image could not be read."
            return
        }

        Log.write(.scan, "processing a \(Int(captured.size.width))x\(Int(captured.size.height)) capture")
        failure = nil
        stage = .reading
        do {
            let text = try await BagScanner.readText(from: cgImage)
            ocrText = text
            stage = .extracting
            // Never throws: an Indonesian label the model refuses still comes
            // back as a draft filled from the label vocabulary alone.
            draft = await BagScanner.draft(fromOCR: text)
            stage = .ready
            Log.write(.scan, "ready for confirmation")
        } catch {
            // A failed read still leaves the manual path open rather than
            // ending the flow, so a bad photo does not cost the user the bag.
            Log.write(.failure, "scan failed: \(error)")
            stage = .capture
            failure = "\(error.localizedDescription) You can still enter the bag by hand."
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
