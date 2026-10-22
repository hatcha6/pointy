// A Moamalat card-terminal slip link, encoded the way the terminal prints its QR
// (mirrors frontend/test/support/moamalat_receipt_links.dart). Scanned into the
// open payment sheet, it attaches to the card line of the same amount.
const zlib = require('zlib');

module.exports = function slipUrl(amount, terminalId = '0JA8Y13W') {
  const payload = ['R0001', 'Purchase', '1', JSON.stringify({
    Amount: amount.toFixed(2), TransactionStatus: 'تمت العملية بنجاح', TransactionType: 'Purchase',
    MerchantName: 'متجر تجريبي', TerminalId: terminalId, CardType: 'Local', PAN: '639974*********8809',
    AuthorizationCode: '123456', RRN: '615316000050', STAN: '000123', BATCH: '000001',
    InvoiceNumber: '000456', DateTime: '2026-10-20 12:00:00',
  })].join(';');
  const query = encodeURIComponent(zlib.deflateSync(Buffer.from(payload, 'utf8')).toString('base64'));
  return `https://receipt.moamalat.net:9443/frontTicketDigital/#/digital/ticket?query=${query}`;
};
