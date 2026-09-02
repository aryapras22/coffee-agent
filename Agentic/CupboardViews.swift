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
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            Text("No bags yet.").font(Theme.display).foregroundStyle(Theme.ink)
            Text("Add one from the chat, where scanning a label and checking what it read happen in the conversation. Everything the agent says about what you own reads from here.")
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

    @State private var capturingRoastDate = false
    @State private var reviewingId: UUID?

    var body: some View {
        List {
            if let photo = BagPhotoStore.image(named: bean.bagPhotoFilename) {
                Section {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: Theme.bubbleRadius))
                        .listRowInsets(EdgeInsets())
                }
                .listRowBackground(Theme.paper)
            }

            Section {
                LabelledRow("Roaster", bean.roasterName)
                LabelledRow("Origin", [bean.subregion, bean.island?.label].compactMap { $0 }.joined(separator: ", "))
                LabelledRow("Process", bean.processingMethod?.label)
                LabelledRow("Roast", bean.roastLevel?.label ?? "Not recorded")
                LabelledRow("Roasted", bean.roastDate?.formatted(date: .abbreviated, time: .omitted))
                LabelledRow("Bag", bean.bagWeightGrams.map { "\($0)g" })
                LabelledRow("Grade", bean.grade)
                LabelledRow("Grind", bean.grindSize.label)
                LabelledRow("Provenance", bean.scanConfidence.label)
            }
            .listRowBackground(Theme.paper)

            if !bean.roasterNotes.isEmpty {
                Section("The roaster's words") {
                    Text(bean.roasterNotes.joined(separator: ", "))
                        .font(Theme.reading)
                        .foregroundStyle(Theme.ink)
                    Text("Kept as printed. Some of these are cupping attributes rather than flavours, so they are never filed under a flavour note.")
                        .font(Theme.trace)
                        .foregroundStyle(Theme.inkMuted)
                }
                .listRowBackground(Theme.paper)
            }

            Section("Roast date stamp") {
                if let stamp = BagPhotoStore.image(named: bean.roastDatePhotoFilename) {
                    Image(uiImage: stamp)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .clipShape(.rect(cornerRadius: Theme.bubbleRadius))
                }
                Button(bean.roastDatePhotoFilename == nil ? "Photograph the date stamp" : "Retake it") {
                    capturingRoastDate = true
                }
                .font(Theme.control)
                .foregroundStyle(Theme.accent)
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
                        if session.awaitingReview {
                            // Reviewed in place rather than pushed: the verdict
                            // is one tap, and a screen transition either way
                            // costs more than the answer does.
                            Button {
                                withAnimation(Theme.enter) {
                                    reviewingId = reviewingId == session.id ? nil : session.id
                                }
                            } label: {
                                BrewRow(session: session)
                            }
                            if reviewingId == session.id {
                                BrewReviewPanel(
                                    manager: manager,
                                    session: session,
                                    onFinish: { _ in reviewingId = nil },
                                    onClose: { reviewingId = nil }
                                )
                                .listRowInsets(EdgeInsets())
                            }
                        } else {
                            BrewRow(session: session)
                        }
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
        .fullScreenCover(isPresented: $capturingRoastDate) {
            CameraPicker { captured in
                Task { await manager.attachRoastDatePhoto(captured, to: bean) }
            }
            .ignoresSafeArea()
        }
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
        parts.append(session.outcome?.symptom.label ?? "awaiting review")
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

/// The confirm step the scan pipeline requires. Coffee bags are matte, curved
/// and often dark on dark, so OCR will misread; nothing reaches the store
/// without passing through here.
///
/// Drawn in the transcript rather than presented, so adding a bag is an event
/// in the conversation and the agent can answer about it in the next breath.
/// It scrolls with the thread because it is taller than a pinned panel has
/// room for, and being at the bottom is where the reader already is.
struct BagConfirmCard: View {
    let manager: CupboardManager
    @State var draft: BagScanner.Draft
    let ocrText: String?
    let photo: UIImage?
    /// Nil when the user cancelled, so a caller that wants to say something
    /// about the new bag can tell that apart from a bag never saved.
    let onFinish: (OwnedBean?) -> Void

    @State private var hasRoastDate: Bool
    @State private var roasterNotes: String
    @State private var isSaving = false

    init(
        manager: CupboardManager,
        draft: BagScanner.Draft,
        ocrText: String? = nil,
        photo: UIImage? = nil,
        onFinish: @escaping (OwnedBean?) -> Void
    ) {
        self.manager = manager
        self._draft = State(initialValue: draft)
        self.ocrText = ocrText
        self.photo = photo
        self.onFinish = onFinish
        self._hasRoastDate = State(initialValue: draft.roastDate != nil)
        self._roasterNotes = State(initialValue: draft.roasterNotes.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(ocrText == nil ? "New bag" : "Check the scan")
                    .font(Theme.display)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.md)
                Button("Cancel") { onFinish(nil) }
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkMuted)
            }

            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 110)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 6))
            }

            if let ocrText {
                Text(ocrText)
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.sm)
                    .background(Theme.paper, in: .rect(cornerRadius: 6))
                    .lineLimit(6)

                Text("Read off the label, so check every field. A wrong roast date poisons every freshness answer afterwards.")
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Name", text: $draft.displayName)
            field("Roaster", text: $draft.roasterName)
            field("Region", text: $draft.subregion)

            menu("Island", selection: $draft.island, cases: Island.allCases, label: \.label)
            menu("Process", selection: $draft.processingMethod, cases: ProcessingMethod.allCases, label: \.label)
            menu("Roast", selection: $draft.roastLevel, cases: RoastLevel.allCases, label: \.label)

            VStack(alignment: .leading, spacing: Theme.xs) {
                Toggle("Roast date on the bag", isOn: $hasRoastDate)
                    .font(Theme.control)
                    .tint(Theme.accent)
                if hasRoastDate {
                    DatePicker(
                        "Roasted",
                        selection: Binding(get: { draft.roastDate ?? .now }, set: { draft.roastDate = $0 }),
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .font(Theme.control)
                    .tint(Theme.accent)
                }
            }

            HStack(spacing: Theme.sm) {
                field("Weight in grams", value: $draft.weightGrams)
                field("Grade", text: $draft.grade)
            }

            VStack(alignment: .leading, spacing: Theme.xs) {
                HStack {
                    Text("Sold as").font(Theme.label).foregroundStyle(Theme.inkMuted)
                    Spacer(minLength: Theme.sm)
                    Picker("Sold as", selection: $draft.grindSize) {
                        ForEach(GrindSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                    .font(Theme.control)
                }

                Text(draft.grindSize.isAdjustable
                    ? "Whole bean, so grind stays a variable the dial-in can move."
                    : "Pre-ground, so the dial-in will work on heat and timing instead of sending you to a grinder.")
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.xs) {
                field("The roaster's words", text: $roasterNotes)
                Text("Copied as printed, separated by commas. Cupping words like Clean belong here as much as flavours do.")
                    .font(Theme.trace)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                save()
            } label: {
                Text(isSaving ? "Saving" : "Save bag")
                    .font(Theme.control)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.sm + 2)
                    .background(draft.isSaveable ? Theme.accent : Theme.rule, in: .capsule)
                    .foregroundStyle(draft.isSaveable ? Theme.paper : Theme.inkMuted)
            }
            .disabled(!draft.isSaveable || isSaving)
        }
        .padding(Theme.md)
        .background(Theme.paperRaised, in: .rect(cornerRadius: Theme.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                .stroke(Theme.rule, lineWidth: Theme.hairline)
        )
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkMuted)
            TextField(label, text: text)
                .font(Theme.control)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.sm)
                .padding(.vertical, Theme.xs + 2)
                .background(Theme.paper, in: .rect(cornerRadius: 6))
        }
    }

    private func field(_ label: String, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkMuted)
            TextField(label, value: value, format: .number)
                .font(Theme.control)
                .keyboardType(.numberPad)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.sm)
                .padding(.vertical, Theme.xs + 2)
                .background(Theme.paper, in: .rect(cornerRadius: 6))
        }
    }

    /// "Not stated" is a real answer on a bag label, so every one of these
    /// keeps a nil case rather than defaulting to a plausible value.
    ///
    /// The title is drawn alongside rather than left to the picker: outside a
    /// `Form`, a menu picker shows only its selected value, and three bare
    /// dropdowns reading Java, Washed and Medium name nothing.
    private func menu<Value: Hashable & CaseIterable>(
        _ title: String,
        selection: Binding<Value?>,
        cases: [Value],
        label: KeyPath<Value, String>
    ) -> some View {
        HStack {
            Text(title).font(Theme.label).foregroundStyle(Theme.inkMuted)
            Spacer(minLength: Theme.sm)
            Picker(title, selection: selection) {
                Text("Not stated").tag(Value?.none)
                ForEach(cases, id: \.self) { Text($0[keyPath: label]).tag(Value?.some($0)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .font(Theme.control)
        }
    }

    /// Confirming is what promotes a scan from unverified to checked, which is
    /// the only signal downstream has that a human looked at these fields.
    private func save() {
        Log.write(.ui, "bag confirmed by hand, promoting \(draft.scanConfidence.rawValue)")
        isSaving = true
        var confirmed = draft
        if !hasRoastDate { confirmed.roastDate = nil }
        if confirmed.scanConfidence == .scanUnverified { confirmed.scanConfidence = .scanConfirmed }
        confirmed.roasterNotes = roasterNotes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Saving the photo and matching the corpus both suspend, so the card
        // reports the bag once it exists rather than before.
        Task { onFinish(await manager.add(confirmed, photo: photo)) }
    }
}

/// Capture and read, and nothing else. This is a modal only because
/// `UIImagePickerController` cannot be embedded in a view; the moment the
/// scan has text, the flow hands the draft back and gets out of the way so
/// the confirm step can happen in the conversation.
struct ScanFlowView: View {
    let manager: CupboardManager
    let onExtracted: (BagScanner.Draft, String, UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var stage = Stage.capture
    @State private var failure: String?
    @State private var showingCamera = false
    @State private var pendingImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?

    private enum Stage { case capture, reading, extracting }

    var body: some View {
        NavigationStack {
            capture
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
        // Processing waits for the camera to finish dismissing, so the reading
        // stage is not racing a cover that is still on screen.
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
            stage = .extracting
            // Never throws: an Indonesian label the model refuses still comes
            // back as a draft filled from the label vocabulary alone.
            let draft = await BagScanner.draft(fromOCR: text)
            Log.write(.scan, "ready for confirmation, handing the draft to the thread")
            onExtracted(draft, text, captured)
            dismiss()
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
