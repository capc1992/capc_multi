import { randomUUID } from 'node:crypto';

import {
  IdentityError,
  ownerPermissions,
  type AuthIdentity,
  type CreateBusinessInput,
  type DeviceRecord,
  type IdentityStore,
  type IssuedIdentity,
  type LinkDeviceInput,
  type LoginInput,
} from './identity.js';

interface Account { ownerId: string; businessId: string; email: string; password: string }
interface Link { businessId: string; ownerId: string; expiresAt: number; used: boolean }

export class MemoryIdentityStore implements IdentityStore {
  private readonly accounts: Account[] = [];
  private readonly devices = new Map<string, DeviceRecord & { businessId: string }>();
  private readonly access = new Map<string, AuthIdentity>();
  private readonly refreshTokens = new Map<string, { identity: AuthIdentity; used: boolean }>();
  private readonly links = new Map<string, Link>();

  async createBusiness(input: CreateBusinessInput, _requestKey?: string): Promise<IssuedIdentity> {
    if (this.accounts.some((item) => item.businessId === input.businessId)) throw new IdentityError('business_already_connected', 409);
    const account = { ownerId: randomUUID(), businessId: input.businessId, email: input.email.toLowerCase(), password: input.password };
    this.accounts.push(account);
    this.devices.set(input.deviceId, this.device(input, input.businessId));
    return this.issue(input.businessId, input.deviceId, account.ownerId);
  }

  async login(input: LoginInput, _requestKey?: string): Promise<IssuedIdentity> {
    const account = this.accounts.find((item) => item.businessId === input.businessId && item.email === input.email.toLowerCase() && item.password === input.password);
    const device = this.devices.get(input.deviceId);
    if (!account || device?.businessId !== input.businessId || device.revokedAt) throw new IdentityError('invalid_credentials', 401);
    return this.issue(input.businessId, input.deviceId, account.ownerId);
  }

  async refresh(refreshToken: string, deviceId: string, _requestKey?: string): Promise<IssuedIdentity> {
    const saved = this.refreshTokens.get(refreshToken);
    if (!saved || saved.used || saved.identity.deviceId !== deviceId) throw new IdentityError('invalid_refresh_token', 401);
    saved.used = true;
    for (const [token, identity] of this.access) if (identity.sessionId === saved.identity.sessionId) this.access.delete(token);
    return this.issue(saved.identity.businessId, deviceId, saved.identity.ownerId);
  }

  async authenticate(accessToken: string): Promise<AuthIdentity | null> {
    const identity = this.access.get(accessToken);
    if (!identity || this.devices.get(identity.deviceId)?.revokedAt) return null;
    return structuredClone(identity);
  }

  async createLinkCode(identity: AuthIdentity): Promise<{ code: string; expiresAt: string }> {
    const code = randomUUID().replaceAll('-', '').slice(0, 10).toUpperCase();
    const expiresAt = Date.now() + 600_000;
    this.links.set(code, { businessId: identity.businessId, ownerId: identity.ownerId, expiresAt, used: false });
    return { code, expiresAt: new Date(expiresAt).toISOString() };
  }

  async linkDevice(input: LinkDeviceInput, _requestKey?: string): Promise<IssuedIdentity> {
    const link = this.links.get(input.code.toUpperCase());
    if (!link || link.expiresAt <= Date.now()) throw new IdentityError('link_code_invalid_or_expired', 409);
    if (link.used) throw new IdentityError('link_code_used', 409);
    if (input.localBusinessId !== link.businessId && this.accounts.some((item) => item.businessId === input.localBusinessId)) {
      throw new IdentityError('local_business_belongs_to_another_remote_business', 409);
    }
    const existing = this.devices.get(input.deviceId);
    if (existing && existing.businessId !== link.businessId) throw new IdentityError('device_belongs_to_another_business', 409);
    link.used = true;
    this.devices.set(input.deviceId, this.device(input, link.businessId));
    return this.issue(link.businessId, input.deviceId, link.ownerId);
  }

  async listDevices(identity: AuthIdentity): Promise<DeviceRecord[]> {
    return [...this.devices.values()].filter((item) => item.businessId === identity.businessId).map(({ businessId: _businessId, ...item }) => ({ ...item, current: item.id === identity.deviceId }));
  }

  async revokeDevice(identity: AuthIdentity, deviceId: string): Promise<void> {
    const device = this.devices.get(deviceId);
    if (!device || device.businessId !== identity.businessId) throw new IdentityError('device_not_found', 404);
    device.revokedAt = new Date().toISOString();
    for (const [token, saved] of this.access) if (saved.deviceId === deviceId) this.access.delete(token);
  }

  async logout(identity: AuthIdentity): Promise<void> {
    for (const [token, saved] of this.access) if (saved.sessionId === identity.sessionId) this.access.delete(token);
  }

  async close(): Promise<void> {}

  expireLinkCode(code: string): void {
    const link = this.links.get(code);
    if (link) link.expiresAt = 0;
  }

  private issue(businessId: string, deviceId: string, ownerId: string): IssuedIdentity {
    const accessToken = `access-${randomUUID()}-${randomUUID()}`;
    const refreshToken = `refresh-${randomUUID()}-${randomUUID()}`;
    const identity: AuthIdentity = { businessId, deviceId, ownerId, sessionId: randomUUID(), permissions: [...ownerPermissions] };
    this.access.set(accessToken, identity);
    this.refreshTokens.set(refreshToken, { identity, used: false });
    return { ...identity, accessToken, refreshToken, accessExpiresAt: new Date(Date.now() + 900_000).toISOString(), refreshExpiresAt: new Date(Date.now() + 2_592_000_000).toISOString() };
  }

  private device(input: { deviceId: string; deviceName: string; platform: string }, businessId: string): DeviceRecord & { businessId: string } {
    return { id: input.deviceId, name: input.deviceName, platform: input.platform, businessId, createdAt: new Date().toISOString(), lastSeenAt: null, revokedAt: null, current: false };
  }
}
