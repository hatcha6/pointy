import { useEffect, useRef, useState } from "react";
import { Keyboard } from "lucide-react";
import { Dialog } from "./dialog";
import { useRouter } from "../lib/router";

// Keyboard shortcuts for operators who live in the console: g then a letter
// jumps to a page, n writes an expense, ? shows the list. Never while typing.

const jumps: { key: string; to: string; label: string }[] = [
  { key: "h", to: "/", label: "الرئيسية" },
  { key: "s", to: "/shops", label: "المتاجر" },
  { key: "f", to: "/finance", label: "الأرباح والخسائر" },
  { key: "l", to: "/ledger", label: "دفتر الحسابات" },
  { key: "t", to: "/topups", label: "عمليات الشحن" },
  { key: "w", to: "/wallets", label: "المحافظ" },
  { key: "p", to: "/purchases", label: "عمليات البطاقات" },
  { key: "m", to: "/sms", label: "الرسائل النصية" },
  { key: "a", to: "/activity", label: "سجل العمليات" },
];

function typing(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return !!el?.closest?.("input, textarea, select, [contenteditable], [role=dialog]");
}

export function Shortcuts() {
  const { navigate } = useRouter();
  const [help, setHelp] = useState(false);
  const pendingG = useRef(0);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey || typing(event.target)) return;
      // Arabic keyboards send Arabic letters; event.code is the key's place.
      const letter = event.code.startsWith("Key") ? event.code.slice(3).toLowerCase() : event.key;
      if (Date.now() - pendingG.current < 1200) {
        pendingG.current = 0;
        const jump = jumps.find((j) => j.key === letter);
        if (jump) {
          event.preventDefault();
          navigate(jump.to);
        }
        return;
      }
      if (letter === "g") {
        pendingG.current = Date.now();
      } else if (letter === "n") {
        event.preventDefault();
        navigate("/ledger?do=expense");
      } else if (event.key === "?" || (event.shiftKey && event.code === "Slash")) {
        event.preventDefault();
        setHelp(true);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [navigate]);

  return (
    <Dialog open={help} onClose={() => setHelp(false)} title="اختصارات لوحة المفاتيح" icon={<Keyboard />}>
      <dl className="shortcuts">
        <div>
          <dt>
            <kbd>⌘</kbd> <kbd>K</kbd> أو <kbd>/</kbd>
          </dt>
          <dd>بحث عن متجر أو صفحة أو إجراء</dd>
        </div>
        <div>
          <dt>
            <kbd>N</kbd>
          </dt>
          <dd>تسجيل مصروف</dd>
        </div>
        {jumps.map((j) => (
          <div key={j.key}>
            <dt>
              <kbd>G</kbd> ثم <kbd>{j.key.toUpperCase()}</kbd>
            </dt>
            <dd>{j.label}</dd>
          </div>
        ))}
        <div>
          <dt>
            <kbd>?</kbd>
          </dt>
          <dd>هذه القائمة</dd>
        </div>
      </dl>
    </Dialog>
  );
}
