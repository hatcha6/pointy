#!/bin/zsh
# Release-builds the preview harnesses the site captures from, into <work>/web/<harness>.
#   build.sh [harness ...]     (default: all of them; skips ones already built)
set -e
HERE=${0:A:h}
WORK=${CAPTURE_WORK:-$HERE/.work}
FRONTEND=${HERE:h:h:h}/frontend
HARNESSES=(${@:-pos_preview ai_chat_preview ai_ui_preview operations_preview dashboard_preview cameras_preview
  messaging_preview campaigns_preview conversations_preview product_form_preview reports_preview treasury_preview
  employee_loans_preview subscription_preview stock_count_preview purchasing_preview price_checker_kiosk_preview
  login_preview learning_preview migration_preview register_session_preview balances_preview command_palette_preview
  shop_setup_preview marketing_preview voucher_menu_preview})
mkdir -p $WORK/web
cd $FRONTEND
for h in $HARNESSES; do
  [ -f $WORK/web/$h/main.dart.js ] && { echo "skip $h (built)"; continue; }
  flutter build web --release --no-web-resources-cdn --no-source-maps --no-wasm-dry-run \
    -t lib/dev/$h.dart -o $WORK/web/$h > $WORK/web-$h.log 2>&1 \
    && echo "built $h" || { echo "FAILED $h — see $WORK/web-$h.log"; exit 1; }
done
# The «كروت دفتر» shots (?menu=live) show the live catalog every shop is offered, read
# from the relay (ops/pointy-relay, read-only), with each brand's real logo from
# ops/catalog/logos (the operator's git-ignored catalog workspace).
if [ -d $WORK/web/voucher_menu_preview ]; then
  ROOT=${HERE:h:h:h}; LOGOS=$ROOT/ops/catalog/logos; OUT=$WORK/web/voucher_menu_preview
  [ -d $LOGOS ] || { echo "MISSING $LOGOS — the card shots need the real brand logos"; exit 1; }
  $ROOT/ops/pointy-relay vouchers catalog show --json > $WORK/catalog-show.json \
    || { echo "could not read the live catalog from the relay"; exit 1; }
  python3 $HERE/live_menu.py $WORK/catalog-show.json $OUT/brand-catalog.json
  mkdir -p $OUT/brand-logos
  for k in $(python3 -c "import json,sys; print(' '.join(b['key'] for b in json.load(open(sys.argv[1]))['brands']))" $OUT/brand-catalog.json); do
    cp $LOGOS/$k.png $OUT/brand-logos/ || { echo "no logo for $k"; exit 1; }
  done
fi
