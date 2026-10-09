// Package reloadly is the relay's client for Reloadly (reloadly.com), the
// aggregator the company buys three kinds of prepaid products from with ONE
// account, in US dollars:
//
//   - gift cards (giftcards.go): a code per card, paid from the account;
//   - airtime, data and PIN top-ups (topups.go): operators in 150+ countries;
//   - utility bill payments (utilities.go): electricity, water, TV in a few countries.
//
// The key pair is the company's, like the BN Plus, Resala and Dafa credentials:
// it lives only in relay env and a shop never holds anything it could spend from.
// Shops buy through the relay, which charges their balance first. What a shop is
// charged is the relay's business; this package says what Reloadly charges the
// company (cost.go) and how to talk to it.
//
// Everything below was observed against the SANDBOX (fake money, shared USD
// balance) on 2026-10-08 with real orders, unless it says "live" (read-only GETs
// of the live catalog; a POST to a live host is never made by this package's
// tests). The sandbox is not the live system, see "Sandbox against live".
//
// # Map
//
//   - Client: New, Config, Sandbox, BaseURLs.
//   - Gift cards: Products, Product, OrderGiftCard, GiftRedeemCodes,
//     GiftTransaction, FindGiftTransactions, GiftBalance.
//   - Top-ups: TopupCountries, Operators, Operator, DetectOperator, Topup,
//     TopupAsync, TopupStatus, TopupTransaction, FindTopups, TopupBalance.
//   - Utilities: Billers, Pay, Payment, FindPayments, UtilityBalance.
//   - Pricing, pure and exact: GiftCost, GiftOrderCost, GiftCostBounds,
//     GiftRateBounds, GiftLimits, GiftAmountAllowed, AirtimeCost, AirtimeLimits,
//     AirtimeAmountAllowed, BillCost, BillLimits, BillAmountAllowed, RoundCost.
//   - Failures: Definite, IsDuplicateIdentifier, IsInsufficientBalance, IsNotFound,
//     IsUnauthorized, APIError, TransportError, the Code* constants.
//   - Values: Num (exact decimals), Text, Time (UTC), Labels, Status.
//
// # Calling Reloadly
//
// New builds a Client from a Config. Reads (GET) are retried on network errors,
// 5xx, 429 and 408; PURCHASES (OrderGiftCard, Topup, TopupAsync, Pay) are
// attempted exactly once, never retried: a retry after a lost answer could buy
// twice. Every failure is a *APIError (Reloadly answered with an HTTP error;
// Code, Message, Status and Body are Reloadly's), a *TransportError (no usable
// answer: network, timeout, an unreadable body), or an error wrapping
// ErrInvalidRequest (rejected before any request). Definite(err) says whether a
// failed purchase proves that nothing was bought.
//
// Calls are bounded by Config.MaxConcurrent (8) and timed out per call: 30 s for
// reads, 90 s for purchases (a failing sandbox operator held a top-up 52 s before
// answering). Reloadly closes every connection, so every call pays a TLS
// handshake: 0.7-1.5 s per call from the development machine (the 2961-row gift
// catalog takes 7 s, the operators 5 s). No rate limit was hit with 80 concurrent
// reads, and no rate-limit header is sent.
//
// # Authentication
//
// POST https://auth.reloadly.com/oauth/token with
// {"client_id","client_secret","grant_type":"client_credentials","audience"}
// answers {"access_token","scope","expires_in","token_type"}. The audience is the
// product's base URL, so there are three tokens, cached per audience and
// refreshed five minutes (a quarter of a short lifetime) before expiry; callers
// that find none share one token request. expires_in is 3600 in the sandbox and
// 5184000 (60 days) live. The token service answers 401 INVALID_CREDENTIALS for a
// wrong secret and for a sandbox key against live (or the reverse), 400
// INVALID_AUDIENCE for an unknown audience. A product answers a bad token 401
// INVALID_TOKEN and a missing one 401 MISSING_TOKEN; the client then fetches a
// new token and repeats the call ONCE, a POST included, because a 401 proves
// nothing ran. A token failure is always Definite: no product request was sent.
//
// Product calls send Accept: application/com.reloadly.<product>-v1+json
// (giftcards, topups, utilities). The redeem-code endpoint is asked for v2
// (application/json is a 406). All three services share the account.
//
// # Identifiers: what Reloadly does and does not guarantee
//
// Every purchase carries an identifier of ours: customIdentifier (gift cards,
// top-ups) or referenceId (utilities), at most 150 characters (MaxIdentifierLength,
// else 400 INVALID_INPUT_PROVIDED). Reloadly records it on every ACCEPTED request
// and finds it again (FindGiftTransactions, FindTopups, FindPayments): that is how
// a purchase whose answer was lost is read back.
//
//   - A second request with a used identifier answers HTTP 400
//     CUSTOM_IDENTIFIER_ALREADY_USED (gift cards and top-ups, async included) or
//     400 REFERENCE_ID_ALREADY_USED (utilities, even for a REFUNDED payment).
//     IsDuplicateIdentifier recognises both. The answer does not depend on the rest
//     of the body: only on the identifier.
//   - A REJECTED request (any 4xx) does not use the identifier up; it can be sent
//     again with the same one. A top-up that failed after 52 s left no record.
//   - The check is NOT atomic. Concurrent requests with one identifier all run:
//     5 parallel top-ups = 5 top-ups (5 records), 2 parallel gift orders = 2
//     orders. Utilities serialise partly: of 3 parallel payments one ran and two
//     got 500 TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT. So an identifier makes
//     a SEQUENTIAL retry safe (it either runs the purchase once or answers
//     "already used", after which the order is read back), and it does not make a
//     retry that overlaps a slow first attempt safe. Never send two requests with
//     one identifier at once, and wait out a timed-out attempt (a failing operator
//     can take close to a minute) before resending.
//   - Identifiers are compared case-sensitively when used, case-insensitively when
//     searched (searching "ABC" finds "abc" and "ABC"); the Find methods return
//     every match, oldest first, so compare the identifier you sent.
//   - Spaces, slashes, ?&= and non-ASCII are fine in an identifier (searches
//     encode them).
//
// # Failed purchases: Definite
//
// Definite(err) is true when the request provably did nothing: it never left (bad
// arguments, no token, refused connection, context ended first), or Reloadly
// refused it: 401, 429, or any other 4xx with Reloadly's JSON error body. The
// 5xx answers are NOT definite except 503 OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE
// (raised before anything is attempted; it is also what an unknown operator id
// gets). Not definite: a timeout or reset after the request was written, any other
// 5xx (including the 500 TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT, which the
// sandbox answers as a 400 after a slow operator attempt), a 4xx that is not
// Reloadly's JSON, an unreadable 2xx. Read those back with the Find method of the
// product before returning the shop's money. An empty answer means Reloadly
// recorded nothing, which is final once the request can no longer be in flight.
//
// Errors seen (HTTP status, errorCode; the Code* constants name them):
//
//	400 INVALID_INPUT_PROVIDED            Missing required field X / Invalid amount provided
//	                                      / Maximum length allowed for field customIdentifier is 150
//	400 WRONG_PRODUCT_PRICE               gift card: a face value the product does not sell
//	404 INVALID_PRODUCT                   gift card: unknown product id
//	400 (no code)                         gift card: "cannot order products valued more than
//	                                      100 USD at a go" (sandbox; quantity x unit price)
//	400 INVALID_LOCAL_AMOUNT_FOR_OPERATOR top-up: outside the local limits / not a listed local plan
//	400 LOCAL_AMOUNTS_NOT_SUPPORTED_BY_OPERATOR
//	400 INVALID_RECIPIENT_PHONE           also a country mismatch; OPERATOR_AND_RECIPIENT_PHONE_MISMATCH
//	503 OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE
//	400 INSUFFICIENT_BALANCE              top-up (409 INSUFFICIENT_WALLET_BALANCE for utilities)
//	400 INVALID_AMOUNT                    utilities: below the minimum / above the maximum / no amount
//	400 MISSING_REQUIRED_AMOUNT_ID        utilities, FIXED billers; AMOUNT_ID_NOT_FOUND for a wrong id
//	400 INVALID_BILLER_ID
//	404 COULD_NOT_AUTO_DETECT_OPERATOR    auto-detect; 409 COUNTRY_NOT_SUPPORTED (Libya, among others)
//	404 TRANSACTION_NOT_FOUND             also 404 without a code for an unknown report id
//	404 Spring body                       unknown path: {"timestamp","status":404,"error","path"}
//
// The sandbox could not reproduce an insufficient balance for gift cards (the
// 100 USD order cap prevents it); the client also recognises a "insufficient
// balance/funds" message without a code.
//
// # Money and rounding
//
// Reloadly sends every amount as a JSON number with a varying scale ("505.00000000000",
// "0.19785", "3.8E-5"). Num keeps the literal and Rat() gives the exact value; no
// float64 is ever involved. Debits are rounded to 5 decimals (CostPlaces) and
// shown that way in balanceInfo.cost and amount; fee, discount, smsFee and
// totalFee of a gift order are shown in cents. The gift card ledger keeps six
// decimals (a 3-card order displayed as 6.52838 moved the balance by 6.528382:
// 3 x (1.20013 x 0.98 + 1) = 6.5283822), the top-up ledger five (a top-up
// displayed as 0.19785, exactly 0.1978525, moved it by 0.197850); the utility
// ledger was not measured. Send USD amounts with at most five decimals: beyond
// that the top-up debit drifts by a few millionths from the formula (0.197852508085
// USD moved the balance by 0.187963 where the formula gives 0.187960) and
// balanceInfo.cost, which is derived from the rounded balances, flips between
// 0.18796 and 0.18797 for the very same order. The balance is
// written with six decimals by the gift card and utility services and rounded to
// five by the top-up service: the same number. balanceInfo.updatedAt (and the
// balance's updatedAt) are unreliable: the gift card and utility services write
// them four hours ahead of UTC, the top-up service in UTC, and an order carries
// the stamp from before the order.
//
// # What Reloadly charges the account (cost.go)
//
// Gift cards. Per card, S being the face value times the exchange rate to USD:
//
//	unit  = S x (1 - discount/100 + feePercentage/100) + flatFee
//	total = round5(quantity x unit)
//
// the percentages are of S, both apply, the flat fee is in USD; fee and discount
// apply to EACH card. Verified: Red Lobster $5 with a $1 fee
// 6.00000; Xbox Live US $5 (5% off, $1) 5.75000, two cards 11.50000; Razer Gold
// $5 (1% off, 1% fee, $1) 6.00000; Xbox US $10 (1.5% off, 1% fee, $1) 10.95000;
// App Store France EUR 5 at 1.176776 and a $1 fee 6.88388 (the 5.88 in
// fixedRecipientToSenderDenominationsMap is only that price rounded to cents:
// FIXED cards are NOT charged the map); Amazon UAE AED 5 (0.272294, 1.2% off, $1)
// 2.34513. Giving a recipient phone adds an SMS fee (+0.0081 USD), so the relay
// sends none. A RANGE face value may have up to five decimals. Reloadly publishes the exchange rate rounded to six decimals but
// charges with the unrounded one (EUR ~1.1767764: Netflix Spain EUR 25 cost
// 30.41941, not 30.41940); for VND, IDR, COP the rounding is large (up to 1.3%),
// so GiftRateBounds narrows the rate with the denominations the row publishes
// (the 376 non-USD live products are all consistent with a six-decimal rate and
// cent-rounded dollar amounts) and GiftCostBounds gives the range: guard a margin
// with its upper end.
//
// Airtime. S is the USD amount, or amount / fx.rate for an order in the local
// currency (useLocalAmount), the rate as the catalog writes it:
//
//	cost = round5(S x (1 - discount/100 + feePercentage/100) + flatFee)
//
// USD orders use internationalDiscount (equal to commission in every row) and
// fees.international*; LOCAL orders use localDiscount (usually 0: ordering in the
// local currency forfeits the commission) and fees.local*, the local flat fee being
// in the destination currency and divided by the rate. When the percentage fee is
// not zero the discount is not given (CellCard Cambodia, 4% and 10%: charged x1.10).
// Verified, USD: Orange Mali 4 -> 3.80000; Airtel Niger 0.19786 -> 0.18797 (USD
// amounts take any number of decimals); Claro Peru 1 -> 0.96000; T-Mobile USA PIN
// 10 (3% off, 0.20 flat) -> 9.90000. Local: Airtel Niger 100 XOF at 505.427002 ->
// 0.19785; Orange Mali 2000 XOF at 505 -> 3.96040 (no discount); Claro Peru 3.25
// PEN at 3.2468801 -> 0.99095 (local 1%); Mobitel LK 135 LKR at 270 with a 10% local
// fee -> 0.55000; Hutchison LK 100 LKR at 158.3999939 with a 10 LKR flat fee ->
// 0.69444. A FIXED operator ordered in local currency is priced from the LOCAL
// plan by the rate (Etisalat Egypt 5 EGP -> 5/29.9969997 = 0.16668, not the 0.17
// of its aligned USD plan): the aligned lists only say what a USD plan delivers
// (the 0.17 USD plan, 0.1615 after 5%, delivers 5 EGP). Limits: a RANGE operator's USD bounds are rounded to cents by the
// catalog but applied from the local bounds (Airtel Niger lists 0.20 and took
// 0.19786), see AirtimeLimits.
//
// Utility bills. Same shape; S is the USD amount (useLocalAmount false) or
// amount / fx.rate, and
//
//	USD orders:   international discount / fee percentage / flat fee (USD)
//	LOCAL orders: local discount (0) / local fee percentage / flat fee in the
//	              local currency divided by the rate
//
// Verified: Woyofal Senegal 1000 XOF at 470 with a 117.5 XOF fee -> 2.37766 (the 8%
// international discount is NOT given); the same biller in USD 2.13 -> 1.95960;
// StarTimes Mali plan 400 XOF -> 1.10106 and its USD plan 0.66 -> 0.60720. The
// international plan lists of FIXED billers carry USD prices unrelated to the rate
// (Canal+ Mali live: 10000 XOF costs 18.35 at 545.05, its USD plan is 16.38, or
// 15.07 after the 8% discount); the sandbox takes either without checking, so ask
// Reloadly which the live API wants before paying FIXED billers in USD. A biller's percentage fee (South Africa
// live: 8%) was not observable in the sandbox.
//
// # Phone numbers
//
// recipientPhone is {countryCode, number}; the response gives the number back as
// international digits ("2348031234567"). Accepted: national digits without a trunk
// zero, country code + national, "+" + country code + national, spaces and dashes,
// a lower-case country code, a JSON number. A trunk zero ("0803...") is accepted
// where the country has one (Nigeria; auto-detect also takes it for Egypt) and
// refused where it has none (Niger: 400 INVALID_RECIPIENT_PHONE; auto-detect
// refuses it for Mali). The "00" international prefix is
// accepted only for the country's own IDD (Niger yes, Nigeria no: its prefix is
// 009). Too short or lettered numbers are refused. The safe form is country code +
// national number, with or without "+". The sandbox does not check that the number
// belongs to the operator (only the country), the live API may. Auto-detect
// (DetectOperator) matches by prefix and is lenient with every form above and
// even partial numbers, but refuses a trunk zero where there is none (Mali).
//
// # Statuses and how long they last
//
// SUCCESSFUL, PROCESSING, REFUNDED, FAILED (and PENDING for gift cards, never
// seen). Only SUCCESSFUL delivers; REFUNDED and FAILED deliver nothing and cost
// nothing (balanceInfo.cost 0; a REFUNDED payment still lists the fee).
//
//   - Gift cards: SUCCESSFUL at once; "Mastercard (Virtual)" cards answer PROCESSING
//     and are final at the first read about a second later. Codes can be read as
//     soon as the order exists.
//   - Top-ups: the synchronous endpoint answers the final state. TopupAsync answers
//     {"transactionId"} and the status endpoint answers PROCESSING (with a null
//     transaction) for 8-11 s, then SUCCESSFUL. Reloadly's documentation says FAILED
//     means the operator failed (no debit; wait 30 minutes before trying the number
//     again) and REFUNDED that the operator did not process it (debit returned).
//   - Utilities: POST /pay answers PROCESSING with finalStatusAvailabilityAt (24 h
//     after submission, Reloadly's promise); the sandbox settles within a second.
//     It ends every Nigerian biller payment FAILED or REFUNDED
//     (UNABLE_TO_PROCESS_PAYMENT) and the Senegalese and Malian ones SUCCESSFUL;
//     prepaid tokens (pinDetails) come back null.
//
// # Timestamps and searches
//
// Every timestamp in a body ("2006-01-02 15:04:05": transactionDate,
// transactionCreatedTime, submittedAt, completedAt, the error timeStamp) is UTC and
// read as such. The startDate / endDate filters of the report endpoints are NOT:
// they read their value as UTC-4 wall-clock time (a transaction stored 01:42 UTC
// is found by startDate 21:00 the day before and not by 22:00; America/New_York is
// UTC-4 until November, so it may be that zone). The Find methods therefore widen
// the window by a day and a half on the wire and, without an identifier, clip the
// rows to the exact window. Pages are numbered from 1: page=0 returns page 1, so a
// loop from 0 reads page 1 twice and, stopping at totalPages, never reads the last
// page. The page size is capped per endpoint (gift products 200, gift transactions
// 50, top-up transactions 500, operators/billers 1000), "last" and "totalPages" are
// reliable, a page past the end is empty. The top-up report lists oldest first. A transaction
// report by id answers the transaction itself, a top-up status wraps it
// ({"code","message","status","transaction"}), a utility transaction wraps it
// ({"code","message","transaction"}).
//
// # Sandbox against live
//
// The catalogs differ (sandbox 2961 gift products, live 2375; sandbox 29 billers
// with Nigerian, Kenyan, Ugandan and Malian ones, live 27 including five dollar-only
// ones; the 713 operators are the same but for plans), as do biller fees (the
// sandbox charges flat local fees, live ones are 0). Sandbox leniencies not to
// rely on: senderName and operator-prefix checks are not enforced, a FIXED
// operator took an unlisted USD amount (0.18 for a 0.17 plan), FIXED billers took
// an amount unrelated to their amountId, gift orders above 100 USD are refused (a
// limit that may be different per account). Operator 1213 (Glo Nigeria Special
// Bundle) fails after 52 s with a 400, which is a handy way to see a slow failure.
// Auto-detect for India answers 500 "This feature is only available on live
// environment." with no code: one more reason a 5xx proves nothing.
// Listed field names have two typos in Reloadly's published schema: "balaneInfo"
// (gift transactions) and "localTransactionCurencyCode" (billers); the sandbox
// spells both correctly and both spellings are read.
//
// # Testing
//
// `go test ./internal/reloadly` runs the unit tests against httptest servers and
// fixtures (testdata/ holds raw sandbox answers and live catalog excerpts). The
// sandbox tests are skipped unless RELOADLY_SANDBOX_CLIENT_ID and
// RELOADLY_SANDBOX_CLIENT_SECRET are set; they refuse to run against a non-sandbox
// host and spend about $12 of fake money per run (RELOADLY_SANDBOX_RACE=1 adds the
// concurrent-duplicates experiment, about $1 more):
//
//	set -a; . ops/catalog/.reloadly.env; set +a
//	RELOADLY_SANDBOX_CLIENT_ID=$RELOADLY_CLIENT_ID \
//	RELOADLY_SANDBOX_CLIENT_SECRET=$RELOADLY_CLIENT_SECRET \
//	go test ./internal/reloadly -run Sandbox -v
package reloadly
