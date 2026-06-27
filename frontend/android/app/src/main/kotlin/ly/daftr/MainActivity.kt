package ly.daftr

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val usbChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UsbPrintPlugin.CHANNEL,
        )
        UsbPrintPlugin(applicationContext).register(usbChannel)

        val updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AppUpdatePlugin.CHANNEL,
        )
        AppUpdatePlugin(this).register(updateChannel)
    }
}
