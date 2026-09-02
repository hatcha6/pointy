import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/ai_attachment_picker.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_action.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_host.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_chat_view_model.dart';

class _FakeAiChatRepository extends AiChatRepository {
  _FakeAiChatRepository(this.events) : super(PosApiService());

  List<AiChatEvent> events;
  int? lastConversationId;
  List<AiAttachment> lastAttachments = const [];
  final List<int> truncatedMessageIds = [];
  bool truncateSucceeds = true;

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    lastConversationId = conversationId;
    lastAttachments = attachments;
    for (final event in events) {
      yield event;
    }
  }

  List<AiChatEvent> resumeEvents = const [];
  int? resumeMessageId;
  String? resumeToolCallId;
  List<AiAnswer> resumeAnswers = const [];
  bool resumeDeclined = false;

  @override
  Stream<AiChatEvent> resumeChat({
    required int conversationId,
    required int messageId,
    required String toolCallId,
    List<AiAnswer> answers = const [],
    bool declined = false,
  }) async* {
    resumeMessageId = messageId;
    resumeToolCallId = toolCallId;
    resumeAnswers = answers;
    resumeDeclined = declined;
    for (final event in resumeEvents) {
      yield event;
    }
  }

  Map<String, Object?> applyResult = const {'order_number': 'PO-001'};
  bool applySucceeds = true;
  final List<int> appliedIntakeIds = [];

  @override
  Future<Result<Map<String, Object?>>> applyInvoiceIntake(int intakeId) async {
    appliedIntakeIds.add(intakeId);
    return applySucceeds ? Ok(applyResult) : Error(Exception('fail'));
  }

  @override
  Future<Result<bool>> truncateConversation(
    int conversationId,
    int messageId,
  ) async {
    truncatedMessageIds.add(messageId);
    return truncateSucceeds ? const Ok(true) : Error(Exception('fail'));
  }

  // Keep the rate-limit refresh deterministic (and off the real service).
  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('no usage'));
}

/// Returns a canned image/file so attachment paths can be tested without the
/// platform pickers.
class _FakePicker extends AiAttachmentPicker {
  int imageCalls = 0;

  @override
  Future<AiAttachment?> pickImage({required bool fromCamera}) async {
    imageCalls++;
    return AiAttachment(
      kind: AiAttachmentKind.image,
      dataUri: 'data:image/jpeg;base64,AAAA',
      name: 'p$imageCalls.jpg',
      mime: 'image/jpeg',
    );
  }

  @override
  Future<List<AiAttachment>> pickFiles() async {
    return [
      AiAttachment(
        kind: AiAttachmentKind.file,
        dataUri: 'data:application/pdf;base64,AAAA',
        name: 'f.pdf',
        mime: 'application/pdf',
      ),
    ];
  }
}

void main() {
  test('accumulates deltas in place and finalizes on done', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('Hel'),
      const AiChatDelta('lo'),
      const AiChatDone(conversationId: 7, model: 'm'),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('مرحبا');

    expect(viewModel.messages.length, 2);
    expect(viewModel.messages[0].isUser, isTrue);
    expect(viewModel.messages[0].content, 'مرحبا');
    expect(viewModel.messages[1].isUser, isFalse);
    expect(viewModel.messages[1].content, 'Hello');
    expect(viewModel.messages[1].isStreaming, isFalse);
    expect(viewModel.conversationId, 7);
    expect(viewModel.isStreaming, isFalse);
    expect(viewModel.errorKind, isNull);
  });

  test(
    'sendRecordedAudio sends the clip (no text) as an audio attachment',
    () async {
      final repo = _FakeAiChatRepository([const AiChatDone(conversationId: 3)]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendRecordedAudio(
        AiAttachment(
          kind: AiAttachmentKind.audio,
          dataUri: 'data:audio/wav;base64,QUJD',
          name: 'voice-message.wav',
          mime: 'audio/wav',
          durationMs: 4000,
        ),
      );

      expect(repo.lastAttachments.length, 1);
      expect(repo.lastAttachments.single.kind, AiAttachmentKind.audio);
      final userMessage = viewModel.messages.first;
      expect(userMessage.isUser, isTrue);
      expect(userMessage.content, '');
      expect(userMessage.attachments.single.isAudio, isTrue);
      // Pending list is cleared once the turn is sent.
      expect(viewModel.hasPendingAttachments, isFalse);
    },
  );

  test(
    'streamed deltas notify the message, not the whole view model (jank fix)',
    () async {
      final repo = _FakeAiChatRepository([
        const AiChatDelta('a'),
        const AiChatDelta('b'),
        const AiChatDelta('c'),
        const AiChatDone(conversationId: 1, userMessageId: 1),
      ]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      var vmNotifications = 0;
      viewModel.addListener(() => vmNotifications++);

      await viewModel.sendMessage('hi');

      // The view model fires ONLY on structural change: once for the send (the
      // user + assistant bubbles appear) and once to finalize (streaming flag
      // off). The three deltas in between never reach it — otherwise the app bar,
      // list and composer would rebuild ~25×/sec and every settled reply would
      // re-parse its markdown. That O(messages × tokens) churn was the jank.
      expect(vmNotifications, 2);
      expect(viewModel.messages.last.content, 'abc');
    },
  );

  test('continues the active conversation on the next turn', () async {
    final repo = _FakeAiChatRepository([const AiChatDone(conversationId: 9)]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('first');
    expect(viewModel.conversationId, 9);

    await viewModel.sendMessage('second');
    expect(repo.lastConversationId, 9);
  });

  test('maps a 403 error to notEntitled and drops the empty reply', () async {
    final repo = _FakeAiChatRepository([
      const AiChatError('disabled', statusCode: 403),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hi');

    expect(viewModel.errorKind, AiChatErrorKind.notEntitled);
    expect(viewModel.messages.length, 1);
    expect(viewModel.messages.single.isUser, isTrue);
  });

  test('an in-band error event maps to aiError', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('partial'),
      const AiChatError('model exploded'),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hi');

    expect(viewModel.errorKind, AiChatErrorKind.aiError);
    // Partial text was produced, so the assistant bubble is kept.
    expect(viewModel.messages.last.content, 'partial');
  });

  test(
    'continues without the caller choosing a model (relay auto-routes)',
    () async {
      final repo = _FakeAiChatRepository([const AiChatDone(conversationId: 1)]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendMessage('hi');
      expect(repo.lastConversationId, isNull);
    },
  );

  test('accumulates reasoning separately from the answer', () async {
    final repo = _FakeAiChatRepository([
      const AiChatReasoning('think '),
      const AiChatReasoning('more'),
      const AiChatDelta('answer'),
      const AiChatDone(conversationId: 3),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hi');

    final assistant = viewModel.messages.last;
    expect(assistant.reasoning, 'think more');
    expect(assistant.content, 'answer');
  });

  test('caps attached images at the limit and flags it', () async {
    final repo = _FakeAiChatRepository([]);
    final picker = _FakePicker();
    final viewModel = AiChatViewModel(repo, picker: picker, maxImages: 5);
    addTearDown(viewModel.dispose);

    for (var i = 0; i < 6; i++) {
      await viewModel.addImage(fromCamera: false);
    }

    expect(viewModel.pendingAttachments.length, 5);
    expect(viewModel.canAddImage, isFalse);
    expect(viewModel.imageLimitReached, isTrue);
    // The 6th request was rejected before the picker was invoked.
    expect(picker.imageCalls, 5);
  });

  test('sends an attachment-only turn and forwards the attachments', () async {
    final repo = _FakeAiChatRepository([const AiChatDone(conversationId: 1)]);
    final viewModel = AiChatViewModel(repo, picker: _FakePicker());
    addTearDown(viewModel.dispose);

    await viewModel.addImage(fromCamera: false);
    await viewModel.sendMessage(''); // no text, image only

    expect(repo.lastAttachments.length, 1);
    expect(viewModel.pendingAttachments, isEmpty);
    expect(viewModel.messages.first.attachments.length, 1);
  });

  test('updates the usage snapshot from the done event', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('ok'),
      const AiChatDone(
        conversationId: 1,
        usage: AiUsage(
          fiveHour: AiUsageWindow(used: 6, limit: 30),
          weekly: AiUsageWindow(used: 6, limit: 200),
        ),
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hi');

    expect(viewModel.usage?.fiveHour.used, 6);
    expect(viewModel.usage?.fiveHour.remaining, 24);
  });

  test(
    'an AI title in the done event names the conversation in history',
    () async {
      final repo = _FakeAiChatRepository([
        const AiChatDelta('...'),
        const AiChatDone(conversationId: 5, title: 'أكثر المنتجات مبيعًا'),
      ]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendMessage('ما هي أكثر المنتجات مبيعًا؟');

      // The just-named conversation appears in the local history with its AI title.
      final named = viewModel.conversations.where((c) => c.id == 5).toList();
      expect(named, hasLength(1));
      expect(named.single.title, 'أكثر المنتجات مبيعًا');
    },
  );

  test('maps a 429 to rateLimited', () async {
    final repo = _FakeAiChatRepository([
      const AiChatError('limit reached', statusCode: 429),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hi');

    expect(viewModel.errorKind, AiChatErrorKind.rateLimited);
  });

  test('assigns the user message id from the done event', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('hi'),
      const AiChatDone(conversationId: 1, userMessageId: 42),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('q');

    expect(viewModel.messages.first.id, 42);
  });

  test('retry rewinds (truncates) and regenerates the answer', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('first'),
      const AiChatDone(conversationId: 1, userMessageId: 7),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('q1');
    repo.events = [
      const AiChatDelta('second'),
      const AiChatDone(conversationId: 1, userMessageId: 8),
    ];

    await viewModel.retry(viewModel.messages.first);

    expect(repo.truncatedMessageIds, [7]);
    expect(viewModel.messages.length, 2);
    expect(viewModel.messages.first.content, 'q1');
    expect(viewModel.messages.last.content, 'second');
  });

  test('rewindForEdit returns the text and drops the turn', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('a'),
      const AiChatDone(conversationId: 1, userMessageId: 5),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hello');
    final text = await viewModel.rewindForEdit(viewModel.messages.first);

    expect(text, 'hello');
    expect(viewModel.messages, isEmpty);
    expect(repo.truncatedMessageIds, [5]);
  });

  test('rewind aborts and flags an error when truncation fails', () async {
    final repo = _FakeAiChatRepository([
      const AiChatDelta('a'),
      const AiChatDone(conversationId: 1, userMessageId: 5),
    ])..truncateSucceeds = false;
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('hello');
    final text = await viewModel.rewindForEdit(viewModel.messages.first);

    expect(text, isNull);
    expect(viewModel.messages.length, 2); // unchanged
    expect(viewModel.errorKind, AiChatErrorKind.network);
  });

  group('generated UI', () {
    AiUiSurface surface({String id = 'card1'}) => AiUiSurface(
      surfaceId: id,
      title: 'ملخص',
      components: const [
        {'id': 'root', 'component': 'Text', 'text': 'مرحبا'},
      ],
    );

    test('a ui event attaches the surface to the assistant turn', () async {
      final repository = _FakeAiChatRepository([
        AiChatUi(surface()),
        const AiChatDelta('تم'),
        const AiChatDone(conversationId: 5),
      ]);
      final viewModel = AiChatViewModel(repository);
      addTearDown(viewModel.dispose);
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      viewModel.attachSurfaceHost(host);

      await viewModel.sendMessage('كيف المبيعات؟');

      final assistant = viewModel.messages.last;
      expect(assistant.uiSurfaces, hasLength(1));
      expect(assistant.uiSurfaces.single.surfaceId, 'card1');
      // The renderer has it too, so the bubble can draw it.
      expect(host.isLive('card1'), isTrue);
    });

    test('a surface does not notify the view model per token', () async {
      // Surfaces arrive once per tool result, so they must not reintroduce the
      // per-token view-model churn the streaming path was fixed to avoid.
      final repository = _FakeAiChatRepository([
        const AiChatDelta('a'),
        AiChatUi(surface()),
        const AiChatDelta('b'),
        const AiChatDone(conversationId: 5),
      ]);
      final viewModel = AiChatViewModel(repository);
      addTearDown(viewModel.dispose);
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      viewModel.attachSurfaceHost(host);

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);
      await viewModel.sendMessage('س');

      // Exactly the structural notifications: send, and done.
      expect(notifications, 2);
    });

    test('starting a new conversation clears the rendered cards', () async {
      final repository = _FakeAiChatRepository([
        AiChatUi(surface()),
        const AiChatDone(conversationId: 5),
      ]);
      final viewModel = AiChatViewModel(repository);
      addTearDown(viewModel.dispose);
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      viewModel.attachSurfaceHost(host);

      await viewModel.sendMessage('س');
      expect(host.isLive('card1'), isTrue);

      viewModel.startNewConversation();
      expect(host.isLive('card1'), isFalse);
    });

    test('applying an invoice calls the API, not the model', () async {
      // The user already reviewed the plan on the card; routing the decision
      // back through a language model only adds a chance of it being misread.
      final repository = _FakeAiChatRepository([
        const AiChatDone(conversationId: 5),
      ]);
      final viewModel = AiChatViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.applyInvoiceIntake(
        const AiSurfaceAction(
          kind: AiSurfaceActionKind.submit,
          name: AiChatViewModel.applyInvoiceIntakeAction,
          surfaceId: 'intake-7',
          context: {'intake_id': 7},
        ),
      );

      expect(repository.appliedIntakeIds, [7]);
      // And the assistant is told what now exists.
      expect(viewModel.messages.first.content, contains('7'));
    });

    test('a failed apply surfaces an error and sends no turn', () async {
      final repository = _FakeAiChatRepository([
        const AiChatDone(conversationId: 5),
      ])..applySucceeds = false;
      final viewModel = AiChatViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.applyInvoiceIntake(
        const AiSurfaceAction(
          kind: AiSurfaceActionKind.submit,
          name: AiChatViewModel.applyInvoiceIntakeAction,
          surfaceId: 'intake-7',
          context: {'intake_id': 7},
        ),
      );

      expect(viewModel.errorKind, isNotNull);
      expect(viewModel.messages, isEmpty);
    });

    test(
      'a submitted card becomes an ordinary turn carrying its data',
      () async {
        final repository = _FakeAiChatRepository([
          const AiChatDone(conversationId: 5),
        ]);
        final viewModel = AiChatViewModel(repository);
        addTearDown(viewModel.dispose);
        final host = AiSurfaceHost();
        addTearDown(host.dispose);
        viewModel.attachSurfaceHost(host);

        await viewModel.sendUiInteraction(
          const AiSurfaceAction(
            kind: AiSurfaceActionKind.submit,
            name: 'submit:reorder',
            surfaceId: 'card1',
            data: {'quantity': 12},
          ),
        );

        final sent = viewModel.messages.first;
        expect(sent.isUser, isTrue);
        expect(sent.content, contains('submit:reorder'));
        expect(sent.content, contains('"quantity": 12'));
      },
    );
  });

  AiChatAskUser askUser({
    int conversationId = 5,
    int messageId = 10,
    String toolCallId = 'call_1',
    AiQuestionType type = AiQuestionType.singleSelect,
  }) {
    return AiChatAskUser(
      conversationId: conversationId,
      messageId: messageId,
      toolCallId: toolCallId,
      questions: [
        AiQuestion(
          id: 'q1',
          type: type,
          prompt: 'أي فرع؟',
          config: const {
            'options': [
              {'value': 'main', 'label': 'الرئيسي'},
            ],
          },
        ),
      ],
    );
  }

  test('an ask_user event attaches a question and keeps the bubble', () async {
    final repo = _FakeAiChatRepository([askUser()]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('أضف منتجًا');

    expect(viewModel.messages.length, 2);
    final assistant = viewModel.messages.last;
    expect(assistant.pendingQuestion, isNotNull);
    expect(assistant.pendingQuestion!.questions.single.id, 'q1');
    expect(
      assistant.isStreaming,
      isFalse,
    ); // typing indicator yields to the card
    expect(viewModel.hasPendingQuestion, isTrue);
    expect(viewModel.isStreaming, isFalse);
    expect(viewModel.conversationId, 5); // captured from the ask_user event
  });

  test(
    'submitAnswer resumes with the answer and streams a new bubble',
    () async {
      final repo = _FakeAiChatRepository([askUser()]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendMessage('أضف منتجًا');
      repo.resumeEvents = [
        const AiChatDelta('تمام'),
        const AiChatDone(conversationId: 5),
      ];

      await viewModel.submitAnswer([
        const AiAnswer(
          questionId: 'q1',
          type: AiQuestionType.singleSelect,
          value: 'main',
        ),
      ]);

      expect(repo.resumeMessageId, 10);
      expect(repo.resumeToolCallId, 'call_1');
      expect(repo.resumeAnswers.single.value, 'main');
      expect(repo.resumeDeclined, isFalse);
      expect(viewModel.hasPendingQuestion, isFalse);
      // A fresh assistant bubble carries the continuation; the question bubble
      // stays and is marked resolved (read-only summary).
      expect(viewModel.messages.length, 3);
      expect(viewModel.messages.last.content, 'تمام');
      expect(viewModel.messages[1].submittedAnswers, isNotNull);
    },
  );

  test(
    'skipQuestion resumes with declined and unblocks the composer',
    () async {
      final repo = _FakeAiChatRepository([
        askUser(type: AiQuestionType.confirm),
      ]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendMessage('احذف المنتج');
      repo.resumeEvents = [const AiChatDone(conversationId: 5)];

      await viewModel.skipQuestion();

      expect(repo.resumeDeclined, isTrue);
      expect(repo.resumeAnswers, isEmpty);
      expect(viewModel.hasPendingQuestion, isFalse);
    },
  );

  test('a resumed turn can itself ask another question', () async {
    final repo = _FakeAiChatRepository([
      askUser(messageId: 10, toolCallId: 'call_1'),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('ابدأ');
    repo.resumeEvents = [
      askUser(messageId: 20, toolCallId: 'call_2', type: AiQuestionType.number),
    ];

    await viewModel.submitAnswer([
      const AiAnswer(
        questionId: 'q1',
        type: AiQuestionType.singleSelect,
        value: 'main',
      ),
    ]);

    // The new question is now the active one, on a fresh bubble.
    expect(viewModel.hasPendingQuestion, isTrue);
    expect(viewModel.pendingQuestion!.toolCallId, 'call_2');
    expect(
      viewModel.pendingQuestion!.questions.single.type,
      AiQuestionType.number,
    );
  });

  test('surfaces tool activity as chips on the assistant turn', () async {
    final repo = _FakeAiChatRepository([
      const AiChatToolActivity(
        name: 'query_resource',
        resource: 'orders',
        label: 'المبيعات',
        phase: 'start',
      ),
      const AiChatToolActivity(
        name: 'query_resource',
        resource: 'orders',
        label: 'المبيعات',
        phase: 'done',
        ok: true,
      ),
      const AiChatDelta('٥ مبيعات'),
      const AiChatDone(conversationId: 1),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await viewModel.sendMessage('كم مبيعات اليوم؟');

    final assistant = viewModel.messages.last;
    expect(assistant.toolRuns.length, 1);
    expect(assistant.toolRuns.first.resource, 'orders');
    expect(assistant.toolRuns.first.done, isTrue);
    expect(assistant.toolRuns.first.ok, isTrue);
    expect(assistant.content, '٥ مبيعات');
  });

  test(
    'a create/edit tool activity is flagged as a mutation on its chip',
    () async {
      final repo = _FakeAiChatRepository([
        const AiChatToolActivity(
          name: 'create_resource',
          resource: 'expenses',
          label: 'إنشاء: المصروفات',
          phase: 'start',
          mutates: true,
        ),
        const AiChatToolActivity(
          name: 'create_resource',
          resource: 'expenses',
          label: 'إنشاء: المصروفات',
          phase: 'done',
          ok: true,
          mutates: true,
        ),
        const AiChatDelta('تم تسجيل المصروف'),
        const AiChatDone(conversationId: 1),
      ]);
      final viewModel = AiChatViewModel(repo);
      addTearDown(viewModel.dispose);

      await viewModel.sendMessage('سجّل مصروف كهرباء');

      final run = viewModel.messages.last.toolRuns.single;
      expect(run.mutates, isTrue);
      expect(run.done, isTrue);
      expect(run.label, 'إنشاء: المصروفات');
    },
  );
}
