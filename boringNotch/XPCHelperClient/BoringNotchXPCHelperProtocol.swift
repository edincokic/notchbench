//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Scheduled jobs and listening ports (Jobs & Ports tab). Lists are returned as JSON.
    func listScheduledJobs(with reply: @escaping (Data?) -> Void)
    func runJob(_ label: String, with reply: @escaping (Bool) -> Void)
    func stopJob(_ label: String, with reply: @escaping (Bool) -> Void)
    func openJobLog(_ label: String, with reply: @escaping (Bool) -> Void)
    func listListeningPorts(with reply: @escaping (Data?) -> Void)
    func stopProcessListening(onPort port: Int, pid: Int32, with reply: @escaping (Bool) -> Void)
    // Busiest processes for the System tab (JSON).
    func listTopProcesses(with reply: @escaping (Data?) -> Void)
}

