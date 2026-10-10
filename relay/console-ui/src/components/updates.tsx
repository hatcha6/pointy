import { useState } from "react";
import { Package } from "lucide-react";
import { bytes } from "../lib/files";
import { date } from "../lib/format";
import { channelLabel } from "../lib/labels";
import type { ArtifactMeta, ChannelTarget } from "../lib/types";
import { Badge, Empty, Skeleton } from "./ui";

/**
 * Picks a version from the bundles the relay holds: nothing is typed, so
 * nothing can name a version with no bundle (which would hold a shop
 * silently). The channels already on a version say so beside it.
 */
export function VersionPicker({ bundles, loading, value, onChange, channels = [], current, emptyHint }: {
  bundles: ArtifactMeta[];
  loading?: boolean;
  value: string;
  onChange: (version: string) => void;
  channels?: ChannelTarget[];
  /** The version running now, marked so a rollback reads plainly. */
  current?: string;
  emptyHint?: string;
}) {
  if (loading) return <Skeleton height={120} />;
  if (!bundles.length) {
    return (
      <Empty icon={<Package />} title="لا حزم على الخادم">
        {emptyHint ?? "أضف حزمة من «حزم التحديث» أولاً."}
      </Empty>
    );
  }
  return (
    <div className="version-picker" role="radiogroup">
      {bundles.map((b) => {
        const on = channels.filter((c) => c.target_version === b.version);
        return (
          <button
            type="button"
            role="radio"
            aria-checked={value === b.version}
            key={b.version}
            className={`version-option ${value === b.version ? "on" : ""}`}
            onClick={() => onChange(b.version)}
          >
            <span className="mono version-name">{b.version}</span>
            <span className="faint">
              <bdi className="num">{bytes(b.size)}</bdi> · {date(b.created_at)}
            </span>
            <span className="spacer" />
            {current === b.version && <Badge tone="success">يعمل الآن</Badge>}
            {on.map((c) => (
              <Badge key={c.channel} tone="info">
                {channelLabel(c.channel)}
              </Badge>
            ))}
          </button>
        );
      })}
    </div>
  );
}

const knownChannels = ["stable", "beta", "canary"];

/** The update channel: the three everyone uses, and any other by name. */
export function ChannelPicker({ value, onChange }: { value: string; onChange: (channel: string) => void }) {
  const [other, setOther] = useState(!knownChannels.includes(value) && value !== "");
  return (
    <div className="chips">
      {knownChannels.map((c) => (
        <button
          type="button"
          key={c}
          className={`chip ${!other && value === c ? "on" : ""}`}
          onClick={() => {
            setOther(false);
            onChange(c);
          }}
        >
          {channelLabel(c)}
        </button>
      ))}
      {other ? (
        <input className="input mono" style={{ width: 150, height: 32 }} placeholder="اسم القناة" value={value} autoFocus onChange={(e) => onChange(e.target.value.trim())} />
      ) : (
        <button type="button" className="chip ghost-chip" onClick={() => setOther(true)}>
          قناة أخرى…
        </button>
      )}
    </div>
  );
}
