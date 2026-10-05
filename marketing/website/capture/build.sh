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
  shop_setup_preview marketing_preview})
mkdir -p $WORK/web
cd $FRONTEND
for h in $HARNESSES; do
  [ -f $WORK/web/$h/main.dart.js ] && { echo "skip $h (built)"; continue; }
  flutter build web --release --no-web-resources-cdn --no-source-maps --no-wasm-dry-run \
    -t lib/dev/$h.dart -o $WORK/web/$h > $WORK/web-$h.log 2>&1 \
    && echo "built $h" || { echo "FAILED $h — see $WORK/web-$h.log"; exit 1; }
done
