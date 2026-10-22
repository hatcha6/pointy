"""Turns the relay's live «كروت دفتر» shop view into the menu a shop's till reads.

    python3 live_menu.py <catalog-show.json> <out-menu.json>

<catalog-show.json> is `ops/pointy-relay vouchers catalog show --json`: the
relay's catalog, supply and `view` (what every shop is offered right now, with
live prices and availability). The output has the shape of the shop backend's
`GET /api/integrations/vouchers/menu/` for a manager (each card's cost
included), which lib/dev/voucher_menu_preview.dart loads with `?menu=live`.
Each brand's card art is named by its key; build.sh serves the real logos at
brand-logos/<key>.png.
"""

import json
import sys


def main(src: str, out: str) -> None:
    view = json.load(open(src, encoding="utf-8"))["view"]
    countries = {c["code"]: c["name"] for c in view["countries"]}
    next_variant = 20000
    brands = []
    for index, brand in enumerate(view["brands"]):
        product_id = 9000 + index
        variants, items = [], []
        for item in brand["items"]:
            next_variant += 1
            country = item.get("country") or ""
            name = (
                f"{countries.get(country, country)} · {item['label']}"
                if country
                else item["label"]
            )
            promo = item.get("promo") or {}
            variants.append(
                {
                    "id": next_variant,
                    "product": product_id,
                    "name": name,
                    "sku": f"DFT-{item['key'].upper()}",
                    "unit_price": item["retail_price"],
                    "is_active": True,
                    "is_service": True,
                }
            )
            items.append(
                {
                    "variant_id": next_variant,
                    "key": item["key"],
                    "label": item["label"],
                    "name": name,
                    "country": country,
                    "face_value": item["face_value"],
                    "face_currency": item["face_currency"],
                    "price": item["retail_price"],
                    "regular_price": item.get("regular_retail_price")
                    or item["retail_price"],
                    "badge": promo.get("badge", "") if promo else "",
                    "promo_ends_at": promo.get("ends_at") if promo else None,
                    "available": bool(item.get("available")),
                    "exceeds_float": False,
                    # What the shop pays us: the manager's profit line.
                    "cost": item["unit_price"],
                }
            )
        brands.append(
            {
                "key": brand["key"],
                "name": brand["name"],
                "category": brand["category"],
                "featured": bool(brand.get("featured")),
                "badge": brand.get("badge", ""),
                "has_promo": any(i["badge"] for i in items),
                "redeem_hint": brand.get("redeem_hint", ""),
                "aliases": brand.get("aliases", []),
                "product": {
                    "id": product_id,
                    "name": brand["name"],
                    "is_active": True,
                    "is_service": True,
                    "is_system": True,
                    "system_kind": "voucher",
                    "quantity_on_hand": 0,
                    "primary_image": {
                        "id": product_id,
                        "original_filename": f"{brand['key']}.png",
                        "content_type": "image/png",
                        "content_url": "https://preview.invalid/api/attachments/"
                        f"{product_id}/content/{brand['key']}",
                        "download_url": "https://preview.invalid/api/attachments/"
                        f"{product_id}/download/",
                        "is_primary": True,
                    },
                    "variants": variants,
                },
                "items": items,
            }
        )
    menu = {
        "available": True,
        "provider": "pointy",
        "error_code": "",
        "balance": "345.50",
        "balance_at": view.get("generated_at"),
        "categories": [
            {"key": c["key"], "name": c["name"]} for c in view["categories"]
        ],
        # No flag bytes: the till draws every country's flag from its own
        # bundled assets.
        "countries": [
            {"code": c["code"], "name": c["name"], "flag": None}
            for c in view["countries"]
        ],
        "brands": brands,
        # The card shelf only: direct top-up and bill payments stay off.
        "services": [],
    }
    json.dump(menu, open(out, "w", encoding="utf-8"), ensure_ascii=False)
    cards = sum(len(b["items"]) for b in brands)
    print(f"{len(brands)} brands, {cards} cards -> {out}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
