//
//  OnboardingAll.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct OnboardingAll: View {
    @State private var currentPage = 0
    
    init() {
        UIPageControl.appearance().currentPageIndicatorTintColor = .black
        UIPageControl.appearance().pageIndicatorTintColor = .lightGray
    }

        var body: some View {
            
            VStack {
            
            TabView(selection: $currentPage) {

                Onboarding1()
                    .tag(0)

                Onboarding2()
                    .tag(1)

                Onboarding3()
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background {
            
                                        Image("GetBeta Wall 1")
                                            .resizable()
                                            .scaledToFill()
                                            .ignoresSafeArea()
                                    }
        }
//
}

#Preview {
    OnboardingAll()
}
