//
//  PoseVisualizationView.swift
//  Contoh implementasi toolbar & floating controls bergaya Liquid Glass (iOS 26+)
//  sesuai referensi Figma "3D Visualization Page"
//

import SwiftUI

struct PoseVisualizationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var canUndo = false

    var body: some View {
        NavigationStack {
            ZStack {
                // TODO: ganti dengan SceneKit/RealityKit view untuk ragdoll 3D-nya
                Color(.systemGray6)
                    .ignoresSafeArea()

                floatingControls
                panTool
            }
            .toolbar {
                // Chevron back — pill glass sendiri
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }

                // Fixed spacer memutus grouping otomatis -> jadi capsule terpisah
                ToolbarSpacer(.fixed, placement: .navigationBarLeading)

                // "Delete Visualization" — pill glass sendiri, warna merah (role: .destructive)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Delete Visualization", role: .destructive) {
                        // TODO: aksi delete visualization
                    }
                }

                // "Reset Pose" — pill glass netral
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset Pose") {
                        // TODO: aksi reset pose
                    }
                }

                ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

                // "Edit Pose" — pill glass biru (prominent)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit Pose") {
                        // TODO: masuk mode edit pose
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar) // biar scene 3D kelihatan tembus di belakang toolbar
        }
    }

    // MARK: - Cluster tombol bulat mengambang (kanan): undo, delete, edit
    private var floatingControls: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                circleButton(systemImage: "arrow.uturn.backward") {
                    // TODO: undo perubahan terakhir
                }
                .disabled(!canUndo)

                circleButton(systemImage: "trash") {
                    // TODO: hapus titik/anotasi terpilih
                }

                circleButton(systemImage: "pencil") {
                    // TODO: toggle mode edit pose
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 16)
    }

    // MARK: - Tombol pan/hand (kiri bawah)
    private var panTool: some View {
        circleButton(systemImage: "hand.raised") {
            // TODO: toggle mode pan/orbit kamera pada scene 3D
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
    }

    // MARK: - Helper tombol bulat glass yang reusable
    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
    }
}

#Preview {
    PoseVisualizationView()
}
