import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, Search } from "lucide-react";
import { matches } from "../lib/search";

export type ComboOption = { value: string; label: string; sub?: string; group?: string };

/** Options drawn at once; typing narrows a long list to what matters. */
const shownLimit = 80;

/**
 * A searchable dropdown: shows the chosen option's name, and typing filters by
 * name or key. The list is drawn in a portal so a scrolling table or a dialog
 * never clips it.
 */
export function Combobox({ value, onChange, options, placeholder = "ابحث واختر…", invalid, ariaLabel, id }: {
  value: string;
  onChange: (value: string) => void;
  options: ComboOption[];
  placeholder?: string;
  invalid?: boolean;
  ariaLabel?: string;
  id?: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const [box, setBox] = useState<{ top: number; start: number; width: number; up: boolean; rtl: boolean } | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const selected = options.find((o) => o.value === value);

  const filtered = useMemo(
    () => options.filter((o) => matches(query, o.label, o.value, o.sub ?? "", o.group ?? "")).slice(0, shownLimit),
    [options, query],
  );

  const place = () => {
    const rect = input.current?.getBoundingClientRect();
    if (!rect) return;
    const up = window.innerHeight - rect.bottom < 280 && rect.top > 280;
    // Lined up with the field's start edge: its right edge in Arabic.
    const rtl = getComputedStyle(input.current!).direction === "rtl";
    const start = rtl ? window.innerWidth - rect.right : rect.left;
    setBox({ top: up ? rect.top - 4 : rect.bottom + 4, start, width: Math.max(rect.width, 280), up, rtl });
  };
  useLayoutEffect(() => {
    if (open) place();
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const onScroll = () => place();
    const onDown = (event: MouseEvent) => {
      const target = event.target as Node;
      if (!input.current?.contains(target) && !list.current?.contains(target)) close();
    };
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    document.addEventListener("mousedown", onDown);
    return () => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
      document.removeEventListener("mousedown", onDown);
    };
  }, [open]);
  useEffect(() => {
    list.current?.querySelector<HTMLElement>(`[data-index="${active}"]`)?.scrollIntoView({ block: "nearest" });
  }, [active]);

  function close() {
    setOpen(false);
    setQuery("");
  }
  function choose(option: ComboOption) {
    onChange(option.value);
    close();
  }

  return (
    <>
      <div className={`combo ${invalid ? "invalid" : ""}`}>
        <Search className="combo-icon" />
        <input
          ref={input}
          id={id}
          className={`input ${invalid ? "invalid" : ""}`}
          role="combobox"
          aria-expanded={open}
          aria-label={ariaLabel}
          aria-autocomplete="list"
          autoComplete="off"
          placeholder={selected ? selected.label : placeholder}
          value={open ? query : selected?.label ?? value}
          title={selected ? `${selected.label} (${selected.value})` : value}
          onFocus={() => {
            setOpen(true);
            setActive(0);
          }}
          onClick={() => setOpen(true)}
          onChange={(e) => {
            setQuery(e.target.value);
            setActive(0);
            setOpen(true);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setOpen(true);
              setActive((i) => Math.min(i + 1, filtered.length - 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setActive((i) => Math.max(i - 1, 0));
            } else if (e.key === "Enter" && open) {
              e.preventDefault();
              if (filtered[active]) choose(filtered[active]);
            } else if (e.key === "Escape" && open) {
              e.stopPropagation();
              close();
            } else if (e.key === "Tab") {
              close();
            }
          }}
        />
        <ChevronDown className="combo-chevron" />
      </div>
      {open &&
        box &&
        createPortal(
          <div
            ref={list}
            className="combo-list"
            role="listbox"
            style={{
              ...(box.rtl ? { right: box.start } : { left: box.start }),
              width: box.width,
              ...(box.up ? { bottom: window.innerHeight - box.top } : { top: box.top }),
            }}
          >
            {filtered.length === 0 && <div className="combo-empty">لا نتائج</div>}
            {filtered.map((option, index) => (
              <div
                key={option.value}
                data-index={index}
                role="option"
                aria-selected={option.value === value}
                className={`combo-option ${index === active ? "active" : ""} ${option.value === value ? "selected" : ""}`}
                onMouseEnter={() => setActive(index)}
                onMouseDown={(e) => {
                  // Before the input blurs, so the click lands.
                  e.preventDefault();
                  choose(option);
                }}
              >
                <span>{option.label}</span>
                <span className="mono combo-sub">{option.sub ?? option.value}</span>
              </div>
            ))}
            {filtered.length === shownLimit && <div className="combo-empty">اكتب لتضييق النتائج…</div>}
          </div>,
          document.body,
        )}
    </>
  );
}
