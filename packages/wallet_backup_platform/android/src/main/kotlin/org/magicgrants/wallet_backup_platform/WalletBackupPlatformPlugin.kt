package org.magicgrants.wallet_backup_platform

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Registers [SyncFolderChannel], the metadata backup's sync folder, on every
 * engine. Its file work needs only the application's content resolver; the
 * folder picker needs the activity, so choosing a folder fails while none is
 * attached (a background engine never asks).
 */
class WalletBackupPlatformPlugin : FlutterPlugin, ActivityAware {
    private var folder: SyncFolderChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        folder = SyncFolderChannel(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        folder?.dispose()
        folder = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        folder?.attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        folder?.detach()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        folder?.attach(binding)
    }

    override fun onDetachedFromActivity() {
        folder?.detach()
    }
}
