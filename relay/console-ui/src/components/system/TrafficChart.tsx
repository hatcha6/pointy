import { useId } from "react";
import { count } from "../../lib/format";

const W = 600;
const H = 150;

/**
 * Requests per step over the last minutes, oldest on the right as the page
 * reads, with the failed ones as bars along the floor.
 */
export function TrafficChart({ requests, failed, step }: { requests: number[]; failed: number[]; step: number }) {
  const gradient = useId();
  const n = requests.length;
  const peak = Math.max(1, ...requests);
  const x = (i: number) => W - (i / Math.max(n - 1, 1)) * W;
  const y = (v: number) => H - 6 - (v / peak) * (H - 18);
  const line = requests.map((v, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const area = `${line} L${x(n - 1).toFixed(1)},${H} L${x(0).toFixed(1)},${H} Z`;
  const total = requests.reduce((a, b) => a + b, 0);
  const barWidth = Math.max((W / n) * 0.5, 2);
  const minutes = Math.round((n * step) / 60);

  return (
    <div className="traffic-chart">
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={`${count(total)} طلب في آخر ${minutes} دقائق`}>
        <defs>
          <linearGradient id={gradient} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="var(--primary)" stopOpacity="0.32" />
            <stop offset="100%" stopColor="var(--primary)" stopOpacity="0.02" />
          </linearGradient>
        </defs>
        {[0.25, 0.5, 0.75].map((f) => (
          <line key={f} x1="0" x2={W} y1={H * f} y2={H * f} className="grid-line" />
        ))}
        <path d={area} fill={`url(#${gradient})`} />
        <path d={line} className="traffic-line" vectorEffect="non-scaling-stroke" />
        {failed.map((v, i) =>
          v > 0 ? (
            <rect key={i} x={x(i) - barWidth / 2} width={barWidth} y={y(v)} height={H - y(v)} className="traffic-failed" rx="1.5" />
          ) : null,
        )}
        {requests.map((v, i) => (
          <rect key={`hit-${i}`} x={x(i) - W / n / 2} width={W / n} y="0" height={H} className="traffic-hit">
            <title>{`${count(v)} طلب${failed[i] ? ` · ${count(failed[i])} فشل` : ""} — ${whenLabel((n - 1 - i) * step)}`}</title>
          </rect>
        ))}
      </svg>
      <div className="traffic-axis">
        <span>قبل {minutes} دقائق</span>
        <span className="faint">أعلى خطوة: {count(peak === 1 && total === 0 ? 0 : peak)} طلب لكل {step} ثوانٍ</span>
        <span>الآن</span>
      </div>
      {total === 0 && <div className="traffic-empty">لا طلبات في آخر {minutes} دقائق</div>}
    </div>
  );
}

function whenLabel(secondsAgo: number): string {
  if (secondsAgo === 0) return "الآن";
  if (secondsAgo < 60) return `قبل ${secondsAgo} ثانية`;
  return `قبل ${(secondsAgo / 60).toFixed(1).replace(/\.0$/, "")} دقيقة`;
}

/** A node's traffic in a few pixels. */
export function Sparkline({ values }: { values: number[] }) {
  const n = values.length;
  if (n < 2) return null;
  const peak = Math.max(1, ...values);
  const points = values.map((v, i) => `${(100 - (i / (n - 1)) * 100).toFixed(1)},${(28 - (v / peak) * 24).toFixed(1)}`).join(" ");
  return (
    <svg className="sparkline" viewBox="0 0 100 30" preserveAspectRatio="none" aria-hidden="true">
      <polyline points={points} vectorEffect="non-scaling-stroke" />
    </svg>
  );
}
