//
//  OnboardingFlow.swift
//  SendSociety
//
//  Created by Christofer Theodore on 21/08/26.
//
import SwiftUI

enum OnboardingStep { case initial, one, two, three }

struct OnboardingFlow: View {
    @State private var step: OnboardingStep = .initial
    let onComplete: () -> Void

    var body: some View {
//        switch step {
//        case .initial: InitialScreen(onNext: { step = .one })
//        case .one:     Onboarding1(onNext: { step = .two })
//        case .two:     Onboarding2(onNext: { step = .three })
//        case .three:   Onboarding3(onFinish: onComplete)
//        }
    }
}
