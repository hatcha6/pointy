import { libyanPhone } from "../../lib/cards";

/** A customer's number as Libyans write it, kept left to right inside Arabic text. */
export function Phone({ value }: { value: string | undefined }) {
  return (
    <bdi dir="ltr" className="mono phone">
      {libyanPhone(value)}
    </bdi>
  );
}
