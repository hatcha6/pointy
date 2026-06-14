#ifndef RUNNER_USB_PRINT_CHANNEL_H_
#define RUNNER_USB_PRINT_CHANNEL_H_

#include <flutter/flutter_engine.h>

// Registers the `pointy/usb_print` method channel.
//
// On Windows "native USB" printing is implemented as a RAW spooler passthrough:
// the encoded ESC/POS / label bytes are sent straight through the printer's
// existing Windows driver to the (typically USB-attached) printer queue via
// OpenPrinter/StartDocPrinter(RAW)/WritePrinter. The matching Dart side is
// `UsbPrintTransport`.
//
// The channel is kept alive for the lifetime of the engine.
void RegisterUsbPrintChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_USB_PRINT_CHANNEL_H_
