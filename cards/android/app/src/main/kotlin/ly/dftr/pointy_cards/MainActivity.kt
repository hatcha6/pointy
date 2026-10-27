package ly.dftr.pointy_cards

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

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
}
