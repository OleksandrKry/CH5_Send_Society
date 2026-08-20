//
//  AnnotateToolbar.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//


import SwiftUI

// MARK: - Annotation Selection

enum AnnotationSelection: Equatable {
    case pencil
    case line
    case angle
    case circle
    case arrow
    case text
}

// MARK: - Annotate Toolbar

struct AnnotateToolbar: View {
    
    // MARK: - State
    
    @ObservedObject var annotationState: AnnotationState
    
    @Binding var isUserDrawing: Bool
    
    
    var body: some View {
        VStack(spacing: 12) {
            
            
            
            // MARK: Annotate + Panel
            
            VStack(spacing: 8) {
                // Annotation Panel
                
                if isUserDrawing {
                    AnnotationPanel(
                        annotationState: annotationState
                    )
                    .transition(
                        .scale(scale: 0.95)
                        .combined(with: .opacity)
                    )
                }
                // Pencil
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isUserDrawing.toggle()
                    }
                } label: {
                    Image(systemName: isUserDrawing
                          ? "chevron.down"
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
                
                
            }
        }
    }
}

// MARK: - Annotation Panel

struct AnnotationPanel: View {
    
    @ObservedObject var annotationState: AnnotationState
    
    private var hasAnnotations: Bool {
        !annotationState.strokes.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 4) {
            
            // MARK: Pencil
            
            annotationButton(
                tool: .pen,
                icon: "pencil",
                color: .annotateRed
            )
            
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
            
            // MARK: Undo
            
            Button {
                // TODO: Undo action
                annotationState.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .frame(width: 44, height: 44)
            }
            .disabled(!hasAnnotations)
            .opacity(hasAnnotations ? 1 : 0.4)
            
            
            // MARK: Eraser
            
            Button {
                // TODO: Eraser action
                annotationState.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.primaryDark)
                    .frame(width: 44, height: 44)
            }
            .disabled(!hasAnnotations)
            .opacity(hasAnnotations ? 1 : 0.4)
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
        tool: AnnotationTool,
        icon: String,
        color: Color
    ) -> some View {
        
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                annotationState.selectTool(tool)
            }
        } label: {
            ZStack {
                
                // Selected Background
                
                if annotationState.tool == tool {
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
