//
//  RouteGrade.swift
//  SendSociety
//
//  Created by Christofer Theodore on 17/08/26.
//

import Foundation

enum RouteGrade: String, CaseIterable, Identifiable, Codable {
    case v0 = "V0", v1 = "V1", v2 = "V2", v3 = "V3", v4 = "V4", v5 = "V5",
         v6 = "V6", v7 = "V7", v8 = "V8", v9 = "V9", v10 = "V10", v11 = "V11",
         v12 = "V12", v13 = "V13", v14 = "V14", v15 = "V15"

    var id: String { rawValue }
}
