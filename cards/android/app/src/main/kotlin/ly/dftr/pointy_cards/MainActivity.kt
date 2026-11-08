package ly.dftr.pointy_cards

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telephony.euicc.EuiccManager
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val ESIM_INSTALL_HOST = "esimsetup.android.com"

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ly.dftr.cards/esim")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "device" -> result.success(esimDevice())
                    "install" -> result.success(esimInstall(call.argument<String>("url").orEmpty()))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ly.dftr.cards/install")
            .setMethodCallHandler { call, result ->
                if (call.method == "referrer") {
                    readInstallReferrer(result)
                } else {
                    result.notImplemented()
                }
            }
    }

    // What the phone says about eSIMs. A carrier's own eSIM can be added from an
    // app only with carrier privileges, which a reseller never has, so "install"
    // opens Google's activation link, and the system shows its own screen.
    private fun esimDevice(): Map<String, Any> {
        val hasEuicc = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_EUICC) &&
            getSystemService(EuiccManager::class.java)?.isEnabled == true
        return mapOf(
            "platform" to "android",
            "model" to Build.MODEL,
            "os_version" to Build.VERSION.RELEASE,
            "supports_esim" to hasEuicc,
            "simulator" to (Build.FINGERPRINT.contains("generic") || Build.HARDWARE == "ranchu"),
            "direct_install" to canInstallEsimFromLink(),
        )
    }

    private fun esimInstall(url: String): Boolean {
        val uri = Uri.parse(url)
        // The only place the channel will send a customer: a link from the relay
        // opens the system's eSIM screen, or nothing.
        if (uri.scheme != "https" || uri.host != ESIM_INSTALL_HOST || !canInstallEsimFromLink()) {
            return false
        }
        return runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    addFlags(Intent.FLAG_ACTIVITY_REQUIRE_NON_BROWSER)
                }
            })
        }.isSuccess
    }

    // Something other than a browser takes Google's activation link: Google Play
    // services, and only a recent enough one. Where nothing does, the link would
    // only open a web page, so the app shows the QR and the details instead.
    private fun canInstallEsimFromLink(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        fun handlers(url: String) = packageManager
            .queryIntentActivities(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE),
                PackageManager.MATCH_ALL,
            )
            .map { it.activityInfo.packageName }
            .toSet()
        val browsers = handlers("https://example.com/")
        return (handlers("https://$ESIM_INSTALL_HOST/esim_qrcode_provisioning") - browsers).isNotEmpty()
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
