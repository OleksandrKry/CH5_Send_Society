//
//  InitialScreen.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct InitialScreen: View {
    
    @State private var goToTutorial: Bool = false
    
    var body: some View {
        NavigationStack {
            VStack{
                Spacer()
                
                Text("See it. Learn it. Send it.")
                    .font(.largeTitle)
                
                Spacer()
                
                Button {
                    goToTutorial = true
                } label: {
                    Text("Get Started")
                        .font(.system(size: 24, weight: .medium, design: .default))
                        .padding(.horizontal, 40)
                        .padding(.vertical, 30)
                        .background(Color(red: 75/255, green: 105/255, blue: 141/255))
                        .foregroundColor(.white)
                        .cornerRadius(50)
                }
                .glassEffect()
                .padding(.bottom, 40)
                .navigationDestination(isPresented: $goToTutorial) {
                    TutorialOne()
                }
            }
        }
    }
}

#Preview {
    InitialScreen()
}
