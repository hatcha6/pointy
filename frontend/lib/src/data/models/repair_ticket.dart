import 'package:flutter/foundation.dart';

/// What a repair customer takes home when they leave an item with the shop:
/// proof of what was handed over, to whom, and how to get it back.
///
/// Plain data only, so the PDF can render it in a background isolate the way
/// invoices do. Built from a job by `buildRepairTicket`.
@immutable
class RepairTicket {
  const RepairTicket({
    required this.shopName,
    required this.jobNumber,
    required this.scanCode,
    required this.customerName,
    this.shopHeaderLines = const [],
    this.shopPhone = '',
    this.receivedAt,
    this.dueAt,
    this.customerPhone = '',
    this.devices = const [],
    this.problem = '',
    this.quotedPrice,
    this.diagnosisFee,
    this.warrantyDays = 0,
    this.terms = const [],
    this.receivedBy = '',
    this.footerNote,
  });

  final String shopName;
  final List<String> shopHeaderLines;
  final String shopPhone;

  /// The number the counter reads out and types into the job search.
  final String jobNumber;

  /// What the barcode encodes: see [repairScanCode].
  final String scanCode;
  final DateTime? receivedAt;
  final DateTime? dueAt;
  final String customerName;
  final String customerPhone;
  final List<RepairTicketDevice> devices;

  /// The fault as the customer described it.
  final String problem;
  final double? quotedPrice;

  /// What the diagnosis costs if the customer declines the repair.
  final double? diagnosisFee;
  final int warrantyDays;
  final List<String> terms;

  /// Who took the item in at the counter.
  final String receivedBy;

  /// The shop's receipt footer message, when it has one.
  final String? footerNote;
}

/// One item left with the shop, as the receipt names it.
@immutable
class RepairTicketDevice {
  const RepairTicketDevice({
    required this.name,
    this.identifiers = const [],
    this.color = '',
  });

  /// "Apple iPhone 15 Pro".
  final String name;

  /// Printable identity lines, each already labelled: "IMEI 3567…".
  final List<String> identifiers;
  final String color;
}

/// The part of a job number a barcode carries: `REP-20260924-000123` scans as
/// `20260924-000123`.
///
/// The type prefix adds nothing a scan needs — the date and the id already
/// make the number unique — but it costs four Code 128 symbols in the slow
/// alphabet. Dropped, the symbol is about a quarter narrower, which is what
/// lets it scan off a 38 mm sticker and fit a 58 mm roll at two dots a bar. It
/// is still a substring of the job number, so a scan typed into the job
/// search finds exactly one job.
String repairScanCode(String jobNumber) {
  final trimmed = jobNumber.trim();
  final match = RegExp(r'^[A-Za-z]+-(\d{8}-\d+)$').firstMatch(trimmed);
  return match?.group(1) ?? trimmed;
}
