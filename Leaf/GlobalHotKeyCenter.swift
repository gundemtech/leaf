//
//  GlobalHotKeyCenter.swift
//  Use-case rebuild Track B4 — ⌥⌘L "show Leaf" global hotkey.
//
//  Carbon RegisterEventHotKey is the supported public API for system-wide
//  hotkeys (works for menubar apps with no key window, needs NO extra TCC
//  permission — unlike NSEvent.addGlobalMonitorForEvents which rides on AX).
//  SwiftUI MenuBarExtra offers no public way to open its popover
//  programmatically, so the hotkey opens the main window on Home — the same
//  nudges content, richer surface. Migrating to a literal popover-open is a
//  drop-in if the menubar item ever moves to a hand-rolled NSStatusItem.
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKeyCenter {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var action: (() -> Void)?

  /// ⌥⌘L. Registration failures (e.g. the combo is taken system-wide) are
  /// silently tolerated — the hotkey is sugar, never load-bearing.
  func registerShowLeaf(action: @escaping () -> Void) {
    guard hotKeyRef == nil else { return }
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
          center.action?()
        }
        return noErr
      },
      1, &eventType, selfPtr, &eventHandler
    )

    let hotKeyID = EventHotKeyID(signature: OSType(0x4C45_4146 /* 'LEAF' */), id: 1)
    RegisterEventHotKey(
      UInt32(kVK_ANSI_L),
      UInt32(cmdKey | optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    action = nil
  }
}
