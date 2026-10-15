import { count } from "../../lib/format";

/** "944 عبر WebSocket · 7 عبر TCP القديم", each part kept in its own direction. */
export function Transports({ ws, tcp }: { ws: number; tcp: number }) {
  return (
    <>
      <bdi>{count(ws)} عبر WebSocket</bdi>
      {tcp > 0 && (
        <>
          {" · "}
          <bdi>{count(tcp)} عبر TCP القديم</bdi>
        </>
      )}
    </>
  );
}
