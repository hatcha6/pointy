package ly.dftr.pointy_cards

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A fragment activity: the fingerprint prompt that guards saved codes
// (local_auth) needs one.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The channel the company's notifications arrive on (the manifest
        // names it for Firebase), shown in the phone's settings in Arabic.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("general", "العروض والأخبار", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "referrer" asks Google Play which link installed the app. It answers
        // a map: "status" is "ok" (Play said; "referrer" holds what it kept,
        // utm_campaign=CODE for a campaign link, or an organic install's own
        // words), "none" (this phone will never say: no Play, sideloaded, or
        // not allowed) or "retry" (Play could not be reached now: ask again
        // at the next launch).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ly.dftr.cards/install")
            .setMethodCallHandler { call, result ->
                if (call.method == "referrer") {
                    readInstallReferrer(result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun readInstallReferrer(result: MethodChannel.Result) {
        val client = InstallReferrerClient.newBuilder(applicationContext).build()
        var answered = false
        // Answered once, on the main thread, whatever Play calls back with
        // and however often.
        fun answer(status: String, referrer: String? = null) {
            runOnUiThread {
                if (answered) return@runOnUiThread
                answered = true
                runCatching { client.endConnection() }
                result.success(mapOf("status" to status, "referrer" to referrer))
            }
        }
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    when (code) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            val details = runCatching { client.installReferrer }.getOrNull()
                            if (details == null) {
                                answer("retry")
                            } else {
                                answer("ok", details.installReferrer)
                            }
                        }
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE,
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED ->
                            answer("retry")
                        // FEATURE_NOT_SUPPORTED (no Play Store), DEVELOPER_ERROR,
                        // PERMISSION_ERROR: it will not change.
                        else -> answer("none")
                    }
                }

                override fun onInstallReferrerServiceDisconnected() = answer("retry")
            })
        } catch (error: Exception) {
            // A phone without Play services can refuse the binding outright.
            answer("retry")
        }
    }
}
