/// Client-side mirror of the backend `Conversation` + `ConversationMessage`
/// (apps.crm). List responses omit `messages`; the thread-detail endpoint
/// includes them.
enum ConversationStatus { open, closed }

ConversationStatus conversationStatusFromJson(Object? value) {
  return value?.toString() == 'closed'
      ? ConversationStatus.closed
      : ConversationStatus.open;
}

enum MessageDirection { inbound, outbound }

MessageDirection messageDirectionFromJson(Object? value) {
  return value?.toString() == 'out'
      ? MessageDirection.outbound
      : MessageDirection.inbound;
}

class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.direction,
    required this.body,
    this.authorId,
    this.outboundStatus = '',
    this.createdAt,
  });

  final int id;
  final MessageDirection direction;
  final String body;
  final int? authorId;
  final String outboundStatus; // '' for inbound; queued/sent/delivered/failed
  final DateTime? createdAt;

  bool get isOutbound => direction == MessageDirection.outbound;

  factory ConversationMessage.fromJson(Map<String, Object?> json) {
    return ConversationMessage(
      id: _int(json['id']),
      direction: messageDirectionFromJson(json['direction']),
      body: json['body']?.toString() ?? '',
      authorId: json['author'] is int ? json['author'] as int : null,
      outboundStatus: json['outbound_status']?.toString() ?? '',
      createdAt: _dateOrNull(json['created_at']),
    );
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.phone,
    this.customerId,
    this.customerName = '',
    this.phoneRaw = '',
    this.status = ConversationStatus.open,
    this.lastMessageAt,
    this.lastInboundAt,
    this.unreadCount = 0,
    this.messages = const [],
  });

  final int id;
  final String phone;
  final int? customerId;
  final String customerName;
  final String phoneRaw;
  final ConversationStatus status;
  final DateTime? lastMessageAt;
  final DateTime? lastInboundAt;
  final int unreadCount;
  final List<ConversationMessage> messages;

  /// A human label: the customer's name if known, else the phone number.
  String get title =>
      customerName.trim().isNotEmpty ? customerName.trim() : phone;

  bool get hasUnread => unreadCount > 0;

  factory Conversation.fromJson(Map<String, Object?> json) {
    final rawMessages = json['messages'];
    return Conversation(
      id: _int(json['id']),
      phone: json['phone']?.toString() ?? '',
      customerId: json['customer'] is int ? json['customer'] as int : null,
      customerName: json['customer_name']?.toString() ?? '',
      phoneRaw: json['phone_raw']?.toString() ?? '',
      status: conversationStatusFromJson(json['status']),
      lastMessageAt: _dateOrNull(json['last_message_at']),
      lastInboundAt: _dateOrNull(json['last_inbound_at']),
      unreadCount: _int(json['unread_count']),
      messages: rawMessages is List
          ? rawMessages
                .whereType<Map<String, Object?>>()
                .map(ConversationMessage.fromJson)
                .toList()
          : const [],
    );
  }

  Conversation copyWith({int? unreadCount, List<ConversationMessage>? messages}) {
    return Conversation(
      id: id,
      phone: phone,
      customerId: customerId,
      customerName: customerName,
      phoneRaw: phoneRaw,
      status: status,
      lastMessageAt: lastMessageAt,
      lastInboundAt: lastInboundAt,
      unreadCount: unreadCount ?? this.unreadCount,
      messages: messages ?? this.messages,
    );
  }
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}
