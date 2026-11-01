import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';

export interface OfflineGrantPayload {
  business_id: string;
  device_id: string;
  principal_id: string;
  principal_name: string;
  username: string;
  role_type: 'administrator' | 'operational';
  permissions: string[];
  security_version: number;
  issued_at: string;
  expires_at: string;
}

export class OfflineGrantIssuer {
  private readonly privateKey;
  readonly publicKey: string;

  constructor(secret: string) {
    const seed = createHash('sha256').update(secret).update('\0capc-offline-grant-ed25519').digest();
    this.privateKey = createPrivateKey({
      key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]),
      format: 'der',
      type: 'pkcs8',
    });
    const publicDer = createPublicKey(this.privateKey).export({ format: 'der', type: 'spki' });
    this.publicKey = publicDer.subarray(publicDer.length - 32).toString('base64url');
  }

  issue(input: Omit<OfflineGrantPayload, 'issued_at' | 'expires_at'>): {
    token: string;
    publicKey: string;
    expiresAt: string;
  } {
    const issuedAt = new Date();
    const expiresAt = new Date(issuedAt.getTime() + 72 * 60 * 60_000);
    const payload: OfflineGrantPayload = {
      ...input,
      permissions: [...new Set(input.permissions)].sort(),
      issued_at: issuedAt.toISOString(),
      expires_at: expiresAt.toISOString(),
    };
    const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const signature = sign(null, Buffer.from(encoded), this.privateKey).toString('base64url');
    return { token: `${encoded}.${signature}`, publicKey: this.publicKey, expiresAt: payload.expires_at };
  }
}
