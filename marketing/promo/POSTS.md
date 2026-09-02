# Post copy

Captions for the posters in `out/posters/`. Arabic is the post; the English
line under each is only there so a non-Arabic reader can check it.

Rule for both: **the numbers on the poster and the numbers in the caption are
the same numbers.** Anyone who runs a shop will add them up.

---

## 11-attendance.png — الحضور والانصراف

> الحضور ما عاد ورقة تتنقّل باليد 🖐️
>
> جهاز البصمة اللي عندك في المحل يوصّل الحضور مباشرة إلى **دفتر**:
> ▪️ أيام الحضور والغياب لكل موظف
> ▪️ التأخير والساعات الإضافية بالدقيقة
> ▪️ وفي آخر الشهر، كشف الراتب يحسبها لحاله
>
> في الصورة: 24 يوم حضور من 26، يومين غياب (−200.00 د.ل)، و12 ساعة إضافية
> (+225.00 د.ل) ← صافي الراتب 2,625.00 د.ل. ولا رقم واحد انكتب باليد.
>
> يتكامل مباشرة مع **ZKTeco BioTime** — نفس الخادم اللي تشتغل عليه أجهزة
> البصمة عندك. ما تحتاج تشتري جهاز جديد ولا تغيّر اللي عندك.
>
> #دفتر #ليبيا #نقاط_بيع #الرواتب #البصمة #إدارة_الموظفين

*Integrates with ZKTeco BioTime by name — the fingerprint terminal already on
your wall now fills in the salary sheet:
24/26 days present, 2 absent (−200.00), 12 overtime hours (+225.00), net
2,625.00 — nobody retyped a figure. Works with the ZKTeco/BioTime device you
already own.*

---

## 12-fx.png — أسعار الصرف

**Refresh before posting.** The rate on the poster is the parallel-market close
of **1 September 2026** (cash 9.22, صك 9.45). If it is not posted the same day,
change the four numbers at the top of `src/posters/Fx.tsx` and re-render — the
whole poster, the conversion and the caption figures follow from them.

> سعر الصرف يتحرك… وتسعيرتك واقفة 📉
>
> **دفتر** يجيب لك سعر السوق أول بأول، وتسعّر على السعر اللي تدفع به فعلًا:
> كاش ولا صك.
>
> إغلاق أمس (1 سبتمبر): الدولار كاش **9.22 د.ل** — والصك **9.45 د.ل**.
> الفرق 0.23 د.ل على كل دولار.
>
> يعني صنف تكلفته 120 دولار:
> ▪️ بسعر الكاش = 1,106.40 د.ل
> ▪️ بسعر الصك = 1,134.00 د.ل
> **فرق 27.60 د.ل على القطعة الواحدة.** لو سعّرت بالسعر الغلط، ياكل من ربحك
> وأنت ما تدري.
>
> دفتر يحوّل تكلفة المورّد إلى دينار بالسعر الصحيح، ويوريك الأصناف اللي
> تسعيرتها قديمة ومحتاجة تحديث.
>
> ⚠️ الأسعار استرشادية وتتغيّر خلال اليوم.
>
> #دفتر #ليبيا #سعر_الصرف #الدولار #الاستيراد #تسعير

*The same dollar has two prices depending on how you settle it — 9.22 in cash,
9.45 by bank cheque (صك). On a $120 item that is 27.60 د.ل a piece. Daftar
converts supplier cost at the rate you actually buy at, and flags the prices
that have gone stale.*

---

## Posting notes

- Both are 1080 × 1350 (4:5) — the tallest crop Instagram and Facebook show in
  a feed. Same size as the other ten posters.
- Alternate them in the grid: `11` is on paper, `12` is on ink.
- Don't put the price/rate figures in the first line of the caption; Facebook
  truncates around 125 characters and the hook has to survive that.

---

## 13-ai-invoice.png — الفاتورة بالصورة

> جاتك البضاعة ومعاها ورقة فاتورة؟ صوّرها وخلاص 📸
>
> **دفتر** يقرأ الفاتورة سطر سطر:
> ▪️ يطلّع الأصناف والكميات والتكاليف
> ▪️ يطابقها مع أصنافك — بالباركود أو بالاسم، عربي ولا إنجليزي
> ▪️ الصنف اللي ما يعرفه، يسألك: هذا هو؟ ولا ننشئه جديد؟
> ▪️ ويقترح سعر بيع من هامش ربحك أنت، مش من فراغ
>
> النتيجة: أمر شراء جاهز — تراجعه وتوافق، وما ينحفظ شي قبل موافقتك.
>
> بدل نص ساعة إدخال يدوي، دقيقة.
>
> #دفتر #ليبيا #الذكاء_الاصطناعي #المخزون #أوامر_الشراء

*Photograph the supplier invoice; it extracts every line, matches against your
own catalogue (barcode or name, Arabic or English), asks about what it can't
match, suggests a sale price from your own median markup — and hands you a
draft PO. Nothing is saved until you approve it.*

---

## 14-ai-capabilities.png — المساعد كامل

> مساعد يعرف محلّك — مش شات عام 🤖
>
> داخل **دفتر**، تقدر:
> ▪️ تسأله بالعربية: «شنو أكثر صنف مبيعاً هذا الأسبوع؟» ويجاوب من أرقامك أنت
> ▪️ ترسل له رسالة صوتية بدل ما تكتب
> ▪️ تصوّر له فاتورة المورّد، يطلّع لك أمر شراء
> ▪️ تخليه ينفّذ: ينشئ منتج، يعدّل سعر، يجهّز أمر شراء
> ▪️ يعطيك ملخّص يومي، وينبّهك لصنف قارب ينفد أو دفعة آجل تأخّرت
>
> والقرار يبقى قرارك — ما ينفّذ شيء دون موافقتك.
>
> #دفتر #ليبيا #الذكاء_الاصطناعي #نقاط_بيع #إدارة_المخزون

*The assistant, end to end: Arabic Q&A over the shop's own data, voice notes,
invoice vision, real actions (create a product, change a price, draft a PO), a
daily digest and proactive alerts — none of it executed without approval.*

---

## 15-kiosk.png — وضع كاشف الأسعار

> عندك تابلت قديم في الدرج؟ خلّيه كاشف أسعار 📱
>
> في **دفتر**، وضع كاشف الأسعار يحوّل أي جهاز إلى شاشة للزبون:
> ▪️ الزبون يقرّب المنتج من الكاميرا — بدون ما يمسك شي
> ▪️ أو يمسح الباركود بماسح عادي
> ▪️ يعرض الصورة والسعر والخصم المطبَّق، وينطق السعر بصوت
> ▪️ شاشة كاملة مقفولة برقم سري — الزبون ما يقدر يخرج منها
> ▪️ تشتغل على الشبكة المحلية بدون تسجيل دخول
>
> يعني: الكاشير يبطّل يسمع «بكم هذا؟» عشر مرات في الساعة.
>
> #دفتر #ليبيا #نقاط_بيع #كاشف_الأسعار #تجارة_التجزئة

*Kiosk mode turns a spare tablet into a customer-facing price checker: camera or
scanner, photo + price + live discount, spoken aloud, full-screen behind a PIN,
running unauthenticated on the LAN.*
