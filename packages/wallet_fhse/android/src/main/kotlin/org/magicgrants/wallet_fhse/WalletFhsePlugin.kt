package org.magicgrants.wallet_fhse

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger

/**
 * Registers [SecurityKeyChannel] (FIDO2 security keys over USB and NFC, for
 * FHSE) on every engine with an activity. The FHSE C library itself is the
 * FFI half of this plugin and needs no registration.
 *
 * The channel exists only while an activity is attached: NFC reader mode is
 * bound to the foreground activity, and a background engine (workmanager,
 * the foreground sync service) never talks to a key. Recreated across a
 * configuration change, which cancels any operation in flight.
 */
class WalletFhsePlugin : FlutterPlugin, ActivityAware {
    private var messenger: BinaryMessenger? = null
    private var channel: SecurityKeyChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        disposeChannel()
        messenger = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val messenger = messenger ?: return
        disposeChannel()
        channel = SecurityKeyChannel(binding.activity, messenger)
    }

    override fun onDetachedFromActivityForConfigChanges() = disposeChannel()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = disposeChannel()

    private fun disposeChannel() {
        channel?.dispose()
        channel = null
    }
}
