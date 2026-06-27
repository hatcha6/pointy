package ly.daftr

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Native USB-Host transport for receipt/label printing.
 *
 * Handles USB printer-class (0x07) devices via raw bulk transfer. Serial-bridge
 * chips (FTDI/CH340/CP210x/CDC) are tagged with the `serial:` route and driven by
 * the `usb_serial` plugin on the Dart side instead. The matching Dart transport is
 * `UsbPrintTransport` (`pointy/usb_print`).
 */
class UsbPrintPlugin(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "pointy/usb_print"
        private const val ACTION_USB_PERMISSION = "ly.daftr.USB_PERMISSION"

        // VendorIds of common USB-serial bridge silicon → routed to usb_serial.
        private val SERIAL_VENDOR_IDS = setOf(0x0403, 0x1a86, 0x10c4, 0x067b, 0x2341, 0x1659)
    }

    private val usbManager: UsbManager =
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(channel: MethodChannel) {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "requestPermission" -> requestPermission(call.argument<String>("address"), result)
            "write" -> {
                val address = call.argument<String>("address")
                val bytes = call.argument<ByteArray>("bytes")
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
                runOnExecutor(result) { write(address, bytes, timeoutMs, read = false) }
            }
            "transceive" -> {
                val address = call.argument<String>("address")
                val bytes = call.argument<ByteArray>("bytes")
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 2000
                runOnExecutor(result) { write(address, bytes, timeoutMs, read = true) }
            }
            else -> result.notImplemented()
        }
    }

    private fun runOnExecutor(result: MethodChannel.Result, work: () -> Map<String, Any?>) {
        executor.execute {
            val response = try {
                work()
            } catch (error: Exception) {
                mapOf("success" to false, "message" to "usb error: ${error.message}")
            }
            mainHandler.post { result.success(response) }
        }
    }

    private fun routeFor(device: UsbDevice): String {
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                return "printer"
            }
        }
        if (device.vendorId in SERIAL_VENDOR_IDS) return "serial"
        for (i in 0 until device.interfaceCount) {
            val cls = device.getInterface(i).interfaceClass
            if (cls == UsbConstants.USB_CLASS_COMM || cls == UsbConstants.USB_CLASS_CDC_DATA) {
                return "serial"
            }
        }
        return "printer"
    }

    private fun listDevices(): List<Map<String, Any?>> {
        return usbManager.deviceList.values.map { device ->
            val route = routeFor(device)
            val vid = String.format("%04x", device.vendorId)
            val pid = String.format("%04x", device.productId)
            mapOf(
                "address" to "$route:$vid:$pid",
                "name" to (device.productName ?: device.deviceName),
                "vendorId" to vid,
                "productId" to pid,
                "route" to route,
                "hasPermission" to usbManager.hasPermission(device),
            )
        }
    }

    private fun findDevice(address: String): UsbDevice? {
        // address is "[route:]vid:pid"; the Dart side already strips the route.
        val parts = address.split(":")
        if (parts.size < 2) return null
        val vid = parts[parts.size - 2].toIntOrNull(16) ?: return null
        val pid = parts[parts.size - 1].toIntOrNull(16) ?: return null
        return usbManager.deviceList.values.firstOrNull {
            it.vendorId == vid && it.productId == pid
        }
    }

    private fun requestPermission(address: String?, result: MethodChannel.Result) {
        val device = address?.let { findDevice(it) }
        if (device == null) {
            result.success(mapOf("granted" to false, "message" to "usb device not found"))
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(mapOf("granted" to true, "message" to "permission already granted"))
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                context.unregisterReceiver(this)
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                result.success(
                    mapOf("granted" to granted, "message" to if (granted) "granted" else "denied"),
                )
            }
        }
        registerPermissionReceiver(receiver)
        usbManager.requestPermission(device, permissionIntent())
    }

    /** Fire-and-forget permission prompt used when a print is attempted before access is granted. */
    private fun launchPermissionRequest(device: UsbDevice) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                context.unregisterReceiver(this)
            }
        }
        registerPermissionReceiver(receiver)
        usbManager.requestPermission(device, permissionIntent())
    }

    private fun permissionIntent(): PendingIntent {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
        return PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
    }

    private fun registerPermissionReceiver(receiver: BroadcastReceiver) {
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    private fun write(
        address: String?,
        bytes: ByteArray?,
        timeoutMs: Int,
        read: Boolean,
    ): Map<String, Any?> {
        if (address.isNullOrEmpty() || bytes == null) {
            return mapOf("success" to false, "message" to "usb address and bytes are required")
        }
        val device = findDevice(address)
            ?: return mapOf("success" to false, "message" to "usb device not found")
        if (!usbManager.hasPermission(device)) {
            mainHandler.post { launchPermissionRequest(device) }
            return mapOf(
                "success" to false,
                "message" to "usb permission required — grant access and print again",
            )
        }

        var targetInterface: UsbInterface? = null
        var outEndpoint: UsbEndpoint? = null
        var inEndpoint: UsbEndpoint? = null
        loop@ for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            var ifaceOut: UsbEndpoint? = null
            var ifaceIn: UsbEndpoint? = null
            for (e in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(e)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (ep.direction == UsbConstants.USB_DIR_OUT) ifaceOut = ifaceOut ?: ep
                if (ep.direction == UsbConstants.USB_DIR_IN) ifaceIn = ifaceIn ?: ep
            }
            if (ifaceOut != null) {
                targetInterface = iface
                outEndpoint = ifaceOut
                inEndpoint = ifaceIn
                break@loop
            }
        }
        val iface = targetInterface
        val out = outEndpoint
        if (iface == null || out == null) {
            return mapOf("success" to false, "message" to "no bulk OUT endpoint on device")
        }

        val connection: UsbDeviceConnection = usbManager.openDevice(device)
            ?: return mapOf("success" to false, "message" to "failed to open usb device")
        try {
            if (!connection.claimInterface(iface, true)) {
                return mapOf("success" to false, "message" to "failed to claim usb interface")
            }
            var offset = 0
            val chunk = 16384
            while (offset < bytes.size) {
                val len = minOf(chunk, bytes.size - offset)
                val slice = bytes.copyOfRange(offset, offset + len)
                val sent = connection.bulkTransfer(out, slice, slice.size, timeoutMs)
                if (sent < 0) {
                    return mapOf(
                        "success" to false,
                        "message" to "usb bulk write failed after $offset bytes",
                    )
                }
                offset += sent
            }
            if (read && inEndpoint != null) {
                val buffer = ByteArray(512)
                val n = connection.bulkTransfer(inEndpoint, buffer, buffer.size, timeoutMs)
                val response = if (n > 0) buffer.copyOfRange(0, n) else ByteArray(0)
                return mapOf("success" to true, "message" to "ok", "bytes" to response)
            }
            return mapOf("success" to true, "message" to "usb print sent: $offset bytes")
        } finally {
            connection.releaseInterface(iface)
            connection.close()
        }
    }
}
