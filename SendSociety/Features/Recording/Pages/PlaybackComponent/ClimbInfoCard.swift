//
//  ClimbInfoCard.swift
//  SendSociety
//
//  Created by Christofer Theodore on 14/08/26.
//

import SwiftUI

struct ClimbInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
                    
                    Text("Aug 9, 2026")
                        .font(.body)
                    
                    Text("Grade: V3 / Red")
                        .font(.body)
                    
                    Text("Student: Aji")
                        .font(.body)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primaryBlue)
                .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ClimbInfoCard()
}
