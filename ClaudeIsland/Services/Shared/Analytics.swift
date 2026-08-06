//
//  Analytics.swift
//  ClaudeIsland
//
//  Mixpanel façade that stays silent until the SDK is initialized
//

import Foundation
import Mixpanel

/// Wraps Mixpanel so a call before `start(token:)` is a no-op instead of a trap.
///
/// `Mixpanel.mainInstance()` asserts when the SDK was never initialized, and the
/// app has a path that reaches teardown before that happens: the single-instance
/// guard terminates a duplicate launch early, and `applicationWillTerminate`
/// then still runs. Routing every call through here keeps that from crashing.
enum Analytics {
    /// Set once during launch, before any other thread can reach analytics.
    nonisolated(unsafe) private(set) static var isReady = false

    static func start(token: String) {
        guard !isReady else { return }
        Mixpanel.initialize(token: token)
        isReady = true
    }

    static func identify(distinctId: String) {
        guard isReady else { return }
        Mixpanel.mainInstance().identify(distinctId: distinctId)
    }

    static func registerSuperProperties(_ properties: [String: MixpanelType]) {
        guard isReady else { return }
        Mixpanel.mainInstance().registerSuperProperties(properties)
    }

    static func setPeopleProperties(_ properties: [String: MixpanelType]) {
        guard isReady else { return }
        Mixpanel.mainInstance().people.set(properties: properties)
    }

    static func track(_ event: String) {
        guard isReady else { return }
        Mixpanel.mainInstance().track(event: event)
    }

    static func flush() {
        guard isReady else { return }
        Mixpanel.mainInstance().flush()
    }
}
