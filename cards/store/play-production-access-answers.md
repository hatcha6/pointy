# Google Play production access: answers submitted

Each answer is capped at 300 characters by the form.

## 1. Closed test

**How did you recruit testers?**

Two groups. 19 friends, family and shop owners who use our Daftar POS in Libya, invited through an email list. That alone did not keep 12 people opted in for 14 days, so we also hired a paid testing provider (Grayo, 25 testers) and added them as a second list.

**How easy was it?** Hard

**Tester engagement**

About 20 Android devices installed builds 1.0.0 to 1.3.0. Testers opened the app on repeat days and browsed the card shelf and brand pages. Paid testers abroad could not sign in (a Libyan phone number is needed), so they did not buy. Real users sign in and pay, as they do on our live iOS app.

**Feedback summary**

Collected through the provider's written report, the Play feedback address support@dftr.ly and direct messages from people we know. No crashes or blocking bugs were reported. Comments were light, so we also used PostHog analytics of tester sessions to see where people stopped.

## 2. About the app

**Intended audience**

Adults (18+) in Libya who top up mobile and internet balances or buy game and gift cards, and who today walk to a shop for a scratch card. The app is Arabic-first, with English and French.

**How the app provides value**

Buy a telecom, internet, game or gift card in a minute and pay with a local Libyan bank card or wallet. The code appears in the app at once with a QR and stays saved under My Cards. Prices match shop retail, and an order that fails after payment is returned as credit.

**Expected installs in the first year:** 1,000 to 10,000

## 3. Production readiness

**Changes made during the closed test**

Four builds during the test (1.0.0 to 1.3.0): fixed app links so shared card links open the app on Play installs, clearer search rows, a new card reveal with QR, in-app order status notices, a "report a problem" button on orders, and an order page that shows live status.

**How we decided the app is ready**

Play vitals shows no crash or ANR clusters across 4 builds, run on Android 10 to 13 phones from Samsung, Xiaomi, Oppo, Vivo, Realme and OnePlus. The same code has been live on the App Store since 1 Nov with real customer orders. Data safety, content rating and account deletion are complete.
