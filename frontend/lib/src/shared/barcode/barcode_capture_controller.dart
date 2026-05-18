import 'package:flutter/material.dart';

class BarcodeCaptureController extends ChangeNotifier {
  BarcodeCaptureController({String initialValue = ''})
    : textController = TextEditingController(text: initialValue),
      focusNode = FocusNode();

  final TextEditingController textController;
  final FocusNode focusNode;

  String get value => textController.text;
  String get normalizedValue => normalize(value);

  static String normalize(String barcode) {
    return barcode.trim();
  }

  void requestFocus() {
    focusNode.requestFocus();
  }

  void syncTextChange() {
    notifyListeners();
  }

  void clear({bool refocus = true}) {
    if (textController.text.isEmpty) {
      if (refocus) {
        requestFocus();
      }
      return;
    }
    textController.clear();
    notifyListeners();
    if (refocus) {
      requestFocus();
    }
  }

  String takeSubmittedValue({bool clear = true}) {
    final barcode = normalizedValue;
    if (clear) {
      this.clear();
    }
    return barcode;
  }

  @override
  void dispose() {
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}
