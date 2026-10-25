package com.walkie.walkie_talkie

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Optional: lets "hold volume-down to talk" work while the screen is on and
 * another app is in front. It only looks at key events (no screen content;
 * window events are limited to this app's own package) and only uses
 * volume-down, only while that setting is on.
 */
class PttAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        PttKeys.a11yConnected = true
    }

    override fun onKeyEvent(event: KeyEvent): Boolean =
        PttKeys.onVolumeKey(applicationContext, event)

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        PttKeys.a11yConnected = false
        super.onDestroy()
    }
}
