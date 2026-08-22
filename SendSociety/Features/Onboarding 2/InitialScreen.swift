//
//  InitialScreen.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct InitialScreen: View {
    
    @State private var goToOnboarding: Bool = false
    let onFinish: () -> Void
    
    var body: some View {
        
    
        NavigationStack {
    
                VStack{
                    Spacer()
                
                    Image("GetBeta Logo_Final")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420)
                        .padding(40)
                        .shadow(color: Color.white.opacity(1.0),
                                radius: 30,
                                x: 0,
                                y: 0)
                    
                    Text("See it. Learn it. Send it.")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.black)
                    
                    Spacer()
                    
                    Button {
                        goToOnboarding = true
                    } label: {
                        Text("Get Started")
                            .font(.system(size: 24))
                            .fontWeight(.bold)
                            .padding(.vertical,20)
                            .padding(.horizontal, 120)
                            .background(Color(red: 75/255, green: 105/255, blue: 141/255))
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                            }
                            .glassEffect()
                            .padding(.bottom, 40)
                            .navigationDestination(isPresented: $goToOnboarding) {
                                OnboardingAll(onFinish: onFinish)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background {
                                    Image("GetBeta Wall 1")
                                        .resizable()
                                        .scaledToFill()
                                        .ignoresSafeArea()
                                }
        }
        
    
    }
}

#Preview {
//    InitialScreen(onFinish: <#T##() -> Void#>)
}
