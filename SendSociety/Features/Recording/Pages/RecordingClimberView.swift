//
//  RecordingClimber.swift.swift
//  SendSociety
//
//  Created by Christofer Theodore on 17/08/26.
//

import SwiftUI

/// Shown once, before a new recording SESSION starts — asks which route grade and which climber
/// this whole session is for. Every clip recorded afterward is stamped with these same two values
/// (see `ContentView`). Picking "New Climber" and tapping Start creates a real, saved `Climber` row
/// via `createClimber` — the climber exists in the database before any video does.
struct RecordingClimberView: View {
    let existingClimbers: [Climber]
        let onStart: (RouteGrade, Climber) -> Void
        let onCancel: () -> Void
        let createClimber: (String) throws -> Climber

        private static let newClimberOption = "New Climber"

        @State private var routeGrade: RouteGrade
        @State private var selectedClimberID: UUID?
        @State private var climberName: String
        @State private var errorMessage: String?

        init(
            existingClimbers: [Climber],
            initialRouteGrade: RouteGrade = .v0,
            initialClimber: Climber? = nil,
            onStart: @escaping (RouteGrade, Climber) -> Void,
            onCancel: @escaping () -> Void,
            createClimber: @escaping (String) throws -> Climber
        ) {
            self.existingClimbers = existingClimbers
            self.onStart = onStart
            self.onCancel = onCancel
            self.createClimber = createClimber
            _routeGrade = State(initialValue: initialRouteGrade)
            _selectedClimberID = State(initialValue: initialClimber?.id)
            _climberName = State(initialValue: initialClimber?.name ?? "")
        }

        private var isNewClimber: Bool { selectedClimberID == nil }

        private var canStart: Bool {
            !climberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Picker("Route", selection: $routeGrade) {
                        ForEach(RouteGrade.allCases) { grade in
                            Text(grade.rawValue).tag(grade)
                        }
                    }
                }
                Section("Climber") {
                    Picker("Climber", selection: $selectedClimberID) {
                        Text(Self.newClimberOption).tag(UUID?.none)
                        ForEach(existingClimbers) { climber in
                            Text(climber.name).tag(Optional(climber.id))
                        }
                    }
                    .onChange(of: selectedClimberID) { _, newValue in
                        if let newValue, let climber = existingClimbers.first(where: { $0.id == newValue }) {
                            climberName = climber.name
                        } else {
                            climberName = ""
                        }
                    }

                    TextField("Climber name", text: $climberName)
                        .disabled(!isNewClimber)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Recording")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(!canStart)
                }
            }
        }
    }

    private func start() {
        if let selectedClimberID, let existing = existingClimbers.first(where: { $0.id == selectedClimberID }) {
            onStart(routeGrade, existing)
            return
        }
        do {
            let climber = try createClimber(climberName.trimmingCharacters(in: .whitespacesAndNewlines))
            onStart(routeGrade, climber)
        } catch {
            errorMessage = "Couldn't save this climber: \(error.localizedDescription)"
        }
    }
}
