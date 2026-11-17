package com.nigraantv.audiobox

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// TTS Studio share entry (v1.0.10): the ACTION_SEND intent-filter in
/// AndroidManifest.xml lets other apps share text into this app. The
/// shared text is stashed here (launch + new intent while running)
/// and served one-shot over the `nigraan.tts/share` MethodChannel —
/// Dart reads it via SharedTextService.takeSharedText() and pre-fills
/// the TTS Studio text box. Nothing else in the activity changes.
class MainActivity : FlutterActivity() {
    private var sharedText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("text/") == true
        ) {
            sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nigraan.tts/share",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getSharedText") {
                result.success(sharedText)
                sharedText = null
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nigraan.launcher_icon",
        ).setMethodCallHandler { call, result ->
            if (call.method == "setLauncherIcon") {
                val icon = call.argument<String>("icon") ?: "default"
                result.success(setLauncherIcon(icon))
            } else {
                result.notImplemented()
            }
        }
    }

    /// Launcher icon switch (v1.0.13). "classic" = the red-speaker
    /// alias, anything else = the default icon. Exactly one launcher
    /// component is enabled at all times; DONT_KILL_APP so the
    /// running app is not restarted by the switch — the launcher
    /// picks the new icon up. Never throws.
    private fun setLauncherIcon(icon: String): Boolean {
        return try {
            val pm = packageManager
            val main = ComponentName(this, MainActivity::class.java)
            val classic =
                ComponentName(this, "com.nigraantv.audiobox.LauncherClassic")
            if (icon == "classic") {
                pm.setComponentEnabledSetting(
                    classic,
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
                pm.setComponentEnabledSetting(
                    main,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            } else {
                pm.setComponentEnabledSetting(
                    main,
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
                pm.setComponentEnabledSetting(
                    classic,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}
