import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/wallet_repository.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';

import 'wallet_view_model_test.dart' show FakeWalletRepository, overview;

// A real Libyan IBAN shape with valid check digits.
const payerIban = 'LY83002048000020100120361';

const company = WalletBankAccount(
  id: 'acc-1',
  bank: 'nab',
  bankName: 'مصرف شمال أفريقيا',
  holder: 'الشركة',
  accountNumber: '009011214872016',
  iban: 'LY09007009009011214872016',
);

WalletTopUp transferTopUp({
  WalletTopUpStatus status = WalletTopUpStatus.review,
  String reason = '',
}) => WalletTopUp(
  id: 'bt-1',
  invoiceNo: 'DFW-TRANSFER01',
  method: WalletTopUpMethod.bankTransfer,
  kind: WalletTopUpMethod.kindBankTransfer,
  amount: 150,
  status: status,
  testMode: false,
  createdAt: DateTime(2026, 10, 9, 10),
  errorDetail: reason,
  transfer: const WalletTransferDetails(
    channel: WalletTransferChannel.lyPay,
    payerBank: 'ncb',
    payerAccount: '000020100120361',
    payerIban: payerIban,
  ),
);

class TransferRepository extends FakeWalletRepository {
  final sent = <WalletBankTransferRequest>[];
  Result<WalletTopUpStart> transferResult = Ok(
    WalletTopUpStart(
      topUp: transferTopUp(),
      checkoutUrl: '',
      nextAction: 'bank_transfer',
      replayed: false,
    ),
  );

  @override
  Future<Result<WalletTopUpStart>> startBankTransfer(
    WalletBankTransferRequest request, {
    void Function(int sent, int total)? onProgress,
  }) async {
    sent.add(request);
    onProgress?.call(50, 100);
    return transferResult;
  }
}

WalletOverview transferOverview({List<WalletPayerAccount> saved = const []}) {
  final base = overview();
  return WalletOverview(
    available: true,
    balance: base.balance,
    currency: 'LYD',
    testMode: false,
    topUpOptions: WalletTopUpOptions(
      available: true,
      methods: [
        ...base.topUpOptions!.methods,
        WalletTopUpMethod.bankTransferMethod,
      ],
      minAmount: 10,
      maxAmount: 5000,
      maxDecimals: 2,
      quickAmounts: const [],
      pendingTtl: const Duration(minutes: 30),
      bankTransfer: WalletBankTransferOffer(
        accounts: const [company],
        savedPayers: saved,
      ),
    ),
    recentTopUps: const [],
    recentEntries: const [],
    settings: base.settings,
  );
}

void main() {
  group('Libyan IBANs', () {
    test('check digits are checked the way the relay checks them', () {
      expect(LibyanIban.isValid('LY09007009009011214872016'), isTrue);
      expect(LibyanIban.isValid('ly09 0070 0900 9011 2148 72016'), isTrue);
      expect(LibyanIban.isValid('LY10007009009011214872016'), isFalse);
      expect(LibyanIban.isValid('LY0900700900901121487201'), isFalse);
      // Arabic digits typed on an Arabic keyboard read as Latin ones.
      expect(LibyanIban.isValid('LY٠٩007009009011214872016'), isTrue);
    });

    test('a valid IBAN carries its account number', () {
      expect(
        LibyanIban.accountNumber('LY09007009009011214872016'),
        '009011214872016',
      );
      expect(LibyanIban.accountNumber('LY10007009009011214872016'), isNull);
      expect(LibyanIban.masked(payerIban), 'LY•••0361');
    });
  });

  group('the offer', () {
    test('a relay that takes transfers adds the method after the gateway', () {
      final options = WalletTopUpOptions.fromJson({
        'available': true,
        'methods': [
          {'key': 'dafa_sadad', 'kind': 'otp', 'payer': 'phone'},
        ],
        'bank_transfer': {
          'available': true,
          'accounts': [
            {
              'id': 'acc-1',
              'bank': 'nab',
              'bank_name': 'مصرف شمال أفريقيا',
              'holder': 'الشركة',
              'account_number': '009011214872016',
              'iban': 'LY09007009009011214872016',
            },
          ],
          'saved_payers': [
            {
              'channel': 'onepay',
              'payer_bank': 'ncb',
              'payer_account': '000020100120361',
              'payer_iban': payerIban,
            },
          ],
        },
      });
      expect(options.methods.map((m) => m.key), [
        'dafa_sadad',
        WalletTopUpMethod.bankTransfer,
      ]);
      expect(options.bankTransfer!.accounts.single.holder, 'الشركة');
      expect(
        options.bankTransfer!.savedPayers.single.channel,
        WalletTransferChannel.onePay,
      );
    });

    test('no account set up means no transfer method', () {
      final options = WalletTopUpOptions.fromJson({
        'available': true,
        'methods': const [],
        'bank_transfer': {'available': false, 'accounts': const []},
      });
      expect(options.methods, isEmpty);
      expect(options.bankTransfer, isNull);
    });
  });

  group('the transfer step', () {
    late TransferRepository repository;
    late WalletViewModel viewModel;

    setUp(() async {
      repository = TransferRepository()
        ..walletResult = Ok(
          transferOverview(
            saved: const [
              WalletPayerAccount(
                bank: 'ncb',
                accountNumber: '000020100120361',
                iban: payerIban,
              ),
            ],
          ),
        );
      viewModel = WalletViewModel(
        repository,
        slowPollInterval: const Duration(hours: 1),
      );
      await viewModel.load();
      viewModel.beginTopUp();
      viewModel.selectMethod(WalletTopUpMethod.bankTransfer);
    });

    tearDown(() => viewModel.dispose());

    test('opens on our account, filled with the account used last time', () {
      viewModel.beginBankTransfer(150);
      expect(viewModel.topUpStage, WalletTopUpStage.bankTransfer);
      final transfer = viewModel.transfer;
      expect(transfer.account?.iban, company.iban);
      expect(transfer.payerIban, payerIban);
      expect(transfer.payerBank, 'ncb');
      expect(transfer.canSend, isFalse, reason: 'no receipt yet');
    });

    test('a typed IBAN fills the account number', () {
      viewModel.beginBankTransfer(150);
      final transfer = viewModel.transfer
        ..setPayerAccount('')
        ..setPayerIban('LY09 0070 0900 9011 2148 72016');
      expect(transfer.payerAccount, '009011214872016');
      expect(transfer.ibanValid, isTrue);
    });

    test('sending waits for the team, then shows their verdict', () async {
      viewModel.beginBankTransfer(150);
      viewModel.transfer.attachReceipt(
        const WalletTransferReceipt.file(
          bytes: [1, 2, 3],
          name: 'receipt.png',
          contentType: 'image/png',
        ),
      );
      await viewModel.transfer.send(
        amount: viewModel.transferAmountText(),
        recordAsExpense: true,
      );
      final request = repository.sent.single;
      expect(request.amount, '150');
      expect(request.payerIban, payerIban);
      expect(request.toAccount, 'acc-1');
      expect(viewModel.topUpStage, WalletTopUpStage.awaitingReview);
      expect(viewModel.isPolling, isTrue);

      repository.topUpResult = Ok(
        transferTopUp(
          status: WalletTopUpStatus.rejected,
          reason: 'لم يصل المبلغ',
        ),
      );
      await viewModel.checkActiveTopUp();
      expect(viewModel.topUpStage, WalletTopUpStage.rejected);
      expect(viewModel.activeTopUp?.errorDetail, 'لم يصل المبلغ');
      expect(viewModel.isPolling, isFalse);
    });

    test('a refused send keeps the form, and a retry reuses its key', () async {
      repository.transferResult = const Error(
        WalletException(code: 'network', message: ''),
      );
      viewModel.beginBankTransfer(150);
      viewModel.transfer.attachReceipt(
        const WalletTransferReceipt.fromPhone(attachmentId: 7),
      );
      await viewModel.transfer.send(amount: '150', recordAsExpense: true);
      await viewModel.transfer.send(amount: '150', recordAsExpense: true);
      expect(viewModel.topUpStage, WalletTopUpStage.bankTransfer);
      expect(viewModel.transfer.error?.code, 'network');
      expect(repository.sent, hasLength(2));
      expect(
        repository.sent[0].idempotencyKey,
        repository.sent[1].idempotencyKey,
      );
      expect(repository.sent[1].receipt.attachmentId, 7);
    });

    test('a receipt over the limit is refused here', () {
      viewModel.beginBankTransfer(150);
      viewModel.transfer.attachReceipt(
        WalletTransferReceipt.file(
          bytes: List.filled(10 * 1024 * 1024 + 1, 0),
          name: 'huge.jpg',
          contentType: 'image/jpeg',
        ),
      );
      expect(viewModel.transfer.receipt, isNull);
      expect(viewModel.transfer.error?.code, 'receipt_too_large');
    });
  });
}
