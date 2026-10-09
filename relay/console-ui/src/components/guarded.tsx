import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Fingerprint } from "lucide-react";
import { request } from "../lib/api";
import { withPasskey } from "../lib/stepup";
import { describeError } from "../lib/errors";
import { useToast } from "./toast";

type Options = {
  /** Query keys to refresh when the action succeeds. */
  invalidate?: unknown[][];
  success?: string;
  /** Needs a passkey tap (money and security actions). */
  passkey?: boolean;
};

/**
 * Runs an admin action: with a passkey tap when it moves money or changes who
 * can get in, then refreshes what it changed and says how it went.
 */
export function useAction<T = unknown>(options: Options = {}) {
  const queryClient = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(method: string, path: string, body?: unknown): Promise<T | undefined> {
    setBusy(true);
    setError(null);
    try {
      const result = options.passkey ? await withPasskey<T>(method, path, body) : await request<T>(method, path, body);
      await Promise.all((options.invalidate ?? []).map((queryKey) => queryClient.invalidateQueries({ queryKey })));
      if (options.success) toast.success(options.success);
      return result;
    } catch (caught) {
      const described = describeError(caught);
      setError(described.cancelled ? null : described.detail ? `${described.title} ${described.detail}` : described.title);
      if (!described.cancelled) toast.error(described.title, described.detail);
      return undefined;
    } finally {
      setBusy(false);
    }
  }

  return { run, busy, error, setError };
}

export function PasskeyHint() {
  return (
    <div className="passkey-hint">
      <Fingerprint />
      سيُطلب منك تأكيد العملية بمفتاح المرور (البصمة أو الوجه).
    </div>
  );
}
