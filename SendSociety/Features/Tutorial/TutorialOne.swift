//
//  TutorialOne.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct TutorialOne: View {
    @State private var currentPage = 0
    
    init() {
        UIPageControl.appearance().currentPageIndicatorTintColor = .black
        UIPageControl.appearance().pageIndicatorTintColor = .lightGray
    }

        var body: some View {
            TabView(selection: $currentPage) {

                Tutorial1()
                    .tag(0)

                Tutorial2()
                    .tag(1)

                Tutorial3()
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

        }
}

#Preview {
    TutorialOne()
}
