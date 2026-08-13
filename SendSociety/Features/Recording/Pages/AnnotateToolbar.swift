//
//  AnnotateToolbar.swift
//  SendSociety
//
//  Created by Alan Brian Frederick on 12/08/26.
//

import SwiftUI

// MARK: - Annotation Selection

enum AnnotationSelection: Equatable {
    case line
    case angle
    case circle
    case arrow
    case text
}

// MARK: - Annotate Toolbar

struct AnnotateToolbar: View {
    
    // MARK: - State
    
    @State private var isAnnotationPanelOpen = false
    @State private var selectedTool: AnnotationSelection? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            
            // MARK: Undo
            
            Button {
                // TODO: Undo action
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .frame(width: 48, height: 48)
                    .background(.primaryLightLessOpacity)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(0.8),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: .black.opacity(0.15),
                        radius: 5,
                        y: 2
                    )
            }
            
            // MARK: Eraser
            
            Button {
                // TODO: Eraser action
            } label: {
                Image(systemName: "eraser")
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .frame(width: 48, height: 48)
                    .background(.primaryLightLessOpacity)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                .white.opacity(0.8),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: .black.opacity(0.15),
                        radius: 5,
                        y: 2
                    )
            }
            
            // MARK: Annotate + Panel
            
            VStack(spacing: 8) {
                
                // Pencil
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAnnotationPanelOpen.toggle()
                    }
                } label: {
                    Image(systemName: isAnnotationPanelOpen
                          ? "chevron.up"
                          : "pencil"
                          )
                        .font(.title2)
                        .foregroundStyle(.primaryDark)
                        .frame(width: 56, height: 56)
                        .background(.primaryLightLessOpacity)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(
                                    .white.opacity(0.8),
                                    lineWidth: 1
                                )
                        }
                        .shadow(
                            color: .black.opacity(0.15),
                            radius: 5,
                            y: 2
                        )
                }
                
                // Annotation Panel
                
                if isAnnotationPanelOpen {
                    AnnotationPanel(
                        selectedTool: $selectedTool
                    )
                    .transition(
                        .scale(scale: 0.95)
                        .combined(with: .opacity)
                    )
                }
            }
        }
    }
}

// MARK: - Annotation Panel

struct AnnotationPanel: View {
    
    @Binding var selectedTool: AnnotationSelection?
    
    var body: some View {
        VStack(spacing: 4) {
            
            // MARK: Line
            
            annotationButton(
                tool: .line,
                icon: "line.diagonal",
                color: .annotateRed
            )
            
            // MARK: Angle
            
            annotationButton(
                tool: .angle,
                icon: "angle",
                color: .annotateGreen
            )
            
            // MARK: Circle
            
            annotationButton(
                tool: .circle,
                icon: "circle",
                color: .annotateYellow
            )
            
            // MARK: Arrow
            
            annotationButton(
                tool: .arrow,
                icon: "arrow.up.right",
                color: .annotateBlue
            )
            
            // MARK: Text
            
            annotationButton(
                tool: .text,
                icon: "textformat",
                color: .primaryDark
            )
        }
        .padding(6)
        .background(.primaryLightLessOpacity)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 28
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 28
            )
            .stroke(
                .white.opacity(0.8),
                lineWidth: 1
            )
        }
        .shadow(
            color: .black.opacity(0.15),
            radius: 7,
            y: 3
        )
    }
    
    // MARK: - Annotation Button
    
    private func annotationButton(
        tool: AnnotationSelection,
        icon: String,
        color: Color
    ) -> some View {
        
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTool = tool
            }
        } label: {
            ZStack {
                
                // Selected Background
                
                if selectedTool == tool {
                    Circle()
                        .fill(.white.opacity(0.95))
                }
                
                // Tool Icon
                
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}
