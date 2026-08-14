//
//  AnnotationStrokeModel.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//
import Foundation

struct AnnotationStrokeModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    /// pen: every sampled point along the drag. line: [start, end]. angle: [vertex, endA, endB].
    var points: [CGPoint]
}
