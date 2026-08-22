//
//  OnboardingAll.swift
//  SendSociety
//
//  Created by Christofer Theodore on 21/08/26.
//

import SwiftUI

struct OnboardingAll: View {
    @State private var currentPage = 0
    let onFinish: () -> Void
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
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

                Onboarding3(onFinish: onFinish)
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
//    OnboardingAll(onFinish: <#T##() -> Void#>)
}
