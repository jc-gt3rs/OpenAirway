//
//  main.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import Foundation

NSLog("[AirwayHelper] Starting privileged helper.")

let delegate = HelperService()

// Arm the sustained-overheat safety override. It runs in the daemon, not the
// app, so it keeps protecting the machine while the popover is closed — or
// after the app has been quit with a manual speed still applied.
delegate.startThermalSafetyMonitor()

let listener = NSXPCListener(machServiceName: "com.airway.helper")
listener.delegate = delegate
listener.resume()

NSLog("[AirwayHelper] XPC listener is running.")
RunLoop.current.run()
