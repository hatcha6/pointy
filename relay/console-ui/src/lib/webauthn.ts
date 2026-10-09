// Turns the relay's WebAuthn options (base64url strings) into what the
// browser API takes (ArrayBuffers), and the browser's answer back into JSON.

function fromB64url(value: string): ArrayBuffer {
  const pad = "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob((value + pad).replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function toB64url(buffer: ArrayBuffer | null): string | undefined {
  if (!buffer) return undefined;
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

type Descriptor = { id: string; type: string; transports?: string[] };

export function passkeysSupported(): boolean {
  return typeof window !== "undefined" && !!window.PublicKeyCredential && !!navigator.credentials;
}

export async function createPasskey(options: { publicKey: Record<string, any> }) {
  const pk = options.publicKey;
  const publicKey: PublicKeyCredentialCreationOptions = {
    ...pk,
    challenge: fromB64url(pk.challenge),
    user: { ...pk.user, id: fromB64url(pk.user.id) },
    excludeCredentials: (pk.excludeCredentials ?? []).map((c: Descriptor) => ({ ...c, id: fromB64url(c.id) })),
  } as PublicKeyCredentialCreationOptions;
  const credential = (await navigator.credentials.create({ publicKey })) as PublicKeyCredential | null;
  if (!credential) throw new Error("cancelled");
  const response = credential.response as AuthenticatorAttestationResponse;
  return {
    id: credential.id,
    rawId: toB64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    response: {
      clientDataJSON: toB64url(response.clientDataJSON),
      attestationObject: toB64url(response.attestationObject),
      transports: typeof response.getTransports === "function" ? response.getTransports() : undefined,
    },
    clientExtensionResults: credential.getClientExtensionResults(),
  };
}

export async function getPasskey(options: { publicKey: Record<string, any> }) {
  const pk = options.publicKey;
  const publicKey: PublicKeyCredentialRequestOptions = {
    ...pk,
    challenge: fromB64url(pk.challenge),
    allowCredentials: (pk.allowCredentials ?? []).map((c: Descriptor) => ({ ...c, id: fromB64url(c.id) })),
  } as PublicKeyCredentialRequestOptions;
  const credential = (await navigator.credentials.get({ publicKey })) as PublicKeyCredential | null;
  if (!credential) throw new Error("cancelled");
  const response = credential.response as AuthenticatorAssertionResponse;
  return {
    id: credential.id,
    rawId: toB64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    response: {
      clientDataJSON: toB64url(response.clientDataJSON),
      authenticatorData: toB64url(response.authenticatorData),
      signature: toB64url(response.signature),
      userHandle: toB64url(response.userHandle),
    },
    clientExtensionResults: credential.getClientExtensionResults(),
  };
}

/** True when the operator dismissed the passkey prompt (not an error to shout about). */
export function isCancelled(error: unknown): boolean {
  if (error instanceof DOMException) return error.name === "NotAllowedError" || error.name === "AbortError";
  return error instanceof Error && error.message === "cancelled";
}
