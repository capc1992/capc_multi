import { randomUUID } from 'node:crypto';
import { OfflineGrantIssuer } from './offline_grant.js';

import {
  accessPermissionCatalog,
  IdentityError,
  ownerPermissions,
  type AccessUserLoginInput,
  type ActivateAccessUserInput,
  type AccessRoleRecord,
  type AccessUserRecord,
  type AuthIdentity,
  type CreateAccessUserInput,
  type CreateBusinessInput,
  type CreatedAccessUser,
  type DeleteBusinessInput,
  type DeviceRecord,
  type IdentityStore,
  type IssuedIdentity,
  type LinkDeviceInput,
  type LoginInput,
  type SaveAccessRoleInput,
  type SecurityAuditRecord,
  type UpdateAccessUserInput,
} from './identity.js';

interface Account { ownerId: string; businessId: string; email: string; password: string }
interface Link { businessId: string; ownerId: string; expiresAt: number; used: boolean }
interface MemoryRole extends AccessRoleRecord { businessId: string }
interface MemoryUser extends AccessUserRecord {
  businessId: string;
  remoteOwnerId?: string;
  activationCode?: string;
  activationExpiresAt?: number;
  password?: string;
}

export class MemoryIdentityStore implements IdentityStore {
  private readonly offlineGrants = new OfflineGrantIssuer('memory-identity-store-test-secret');
  private readonly accounts: Account[] = [];
  private readonly devices = new Map<string, DeviceRecord & { businessId: string }>();
  private readonly access = new Map<string, AuthIdentity>();
  private readonly refreshTokens = new Map<string, { identity: AuthIdentity; used: boolean }>();
  private readonly links = new Map<string, Link>();
  private readonly roles = new Map<string, MemoryRole>();
  private readonly users = new Map<string, MemoryUser>();
  private readonly auditRecords: Array<SecurityAuditRecord & { businessId: string }> = [];

  async createBusiness(input: CreateBusinessInput, _requestKey?: string): Promise<IssuedIdentity> {
    if (this.accounts.some((item) => item.businessId === input.businessId)) throw new IdentityError('business_already_connected', 409);
    const account = { ownerId: randomUUID(), businessId: input.businessId, email: input.email.toLowerCase(), password: input.password };
    this.accounts.push(account);
    this.devices.set(input.deviceId, this.device(input, input.businessId));
    const ownerRole: MemoryRole = {
      id: randomUUID(), businessId: input.businessId, name: 'Administrador principal',
      roleType: 'administrator',
      permissions: accessPermissionCatalog.map((item) => item.key), system: true, version: 1,
    };
    this.roles.set(ownerRole.id, ownerRole);
    const ownerUser: MemoryUser = {
      id: randomUUID(), businessId: input.businessId, remoteOwnerId: account.ownerId,
      name: 'Administrador principal', username: `owner_${account.ownerId.replaceAll('-', '')}`,
      email: account.email, active: true, activated: true,
      roles: [{ id: ownerRole.id, name: ownerRole.name }], securityVersion: 1,
    };
    this.users.set(ownerUser.id, ownerUser);
    return this.issue(input.businessId, input.deviceId, account.ownerId, null, [...ownerPermissions]);
  }

  async login(input: LoginInput, _requestKey?: string): Promise<IssuedIdentity> {
    const account = this.accounts.find((item) => item.businessId === input.businessId && item.email === input.email.toLowerCase() && item.password === input.password);
    const device = this.devices.get(input.deviceId);
    if (!account || device?.businessId !== input.businessId || device.revokedAt) throw new IdentityError('invalid_credentials', 401);
    return this.issue(input.businessId, input.deviceId, account.ownerId, null, [...ownerPermissions]);
  }

  async refresh(refreshToken: string, deviceId: string, _requestKey?: string): Promise<IssuedIdentity> {
    const saved = this.refreshTokens.get(refreshToken);
    if (!saved || saved.used || saved.identity.deviceId !== deviceId) throw new IdentityError('invalid_refresh_token', 401);
    saved.used = true;
    for (const [token, identity] of this.access) if (identity.sessionId === saved.identity.sessionId) this.access.delete(token);
    return this.issue(
      saved.identity.businessId,
      deviceId,
      saved.identity.ownerId,
      saved.identity.userId,
      saved.identity.permissions,
    );
  }

  async authenticate(accessToken: string): Promise<AuthIdentity | null> {
    const identity = this.access.get(accessToken);
    if (!identity || this.devices.get(identity.deviceId)?.revokedAt) return null;
    return structuredClone(identity);
  }

  async createLinkCode(identity: AuthIdentity): Promise<{ code: string; expiresAt: string }> {
    if (!identity.ownerId) throw new IdentityError('remote_owner_required', 403);
    const code = randomUUID().replaceAll('-', '').slice(0, 10).toUpperCase();
    const expiresAt = Date.now() + 600_000;
    this.links.set(code, { businessId: identity.businessId, ownerId: identity.ownerId, expiresAt, used: false });
    return { code, expiresAt: new Date(expiresAt).toISOString() };
  }

  async linkDevice(input: LinkDeviceInput, _requestKey?: string): Promise<IssuedIdentity> {
    const link = this.links.get(input.code.toUpperCase());
    if (!link || link.expiresAt <= Date.now()) throw new IdentityError('link_code_invalid_or_expired', 409);
    if (link.used) throw new IdentityError('link_code_used', 409);
    const existing = this.devices.get(input.deviceId);
    if (existing && existing.businessId !== link.businessId) throw new IdentityError('device_belongs_to_another_business', 409);
    if (input.localBusinessId !== link.businessId && this.accounts.some((item) => item.businessId === input.localBusinessId)) {
      throw new IdentityError('local_business_belongs_to_another_remote_business', 409);
    }
    link.used = true;
    this.devices.set(input.deviceId, this.device(input, link.businessId));
    return this.issue(link.businessId, input.deviceId, link.ownerId, null, [...ownerPermissions]);
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

  async listAccessPermissions(_identity: AuthIdentity) {
    return structuredClone(accessPermissionCatalog);
  }

  async listAccessRoles(identity: AuthIdentity): Promise<AccessRoleRecord[]> {
    return [...this.roles.values()]
      .filter((item) => item.businessId === identity.businessId)
      .sort((left, right) => left.name.localeCompare(right.name))
      .map(({ businessId: _businessId, ...item }) => structuredClone(item));
  }

  async saveAccessRole(identity: AuthIdentity, input: SaveAccessRoleInput): Promise<AccessRoleRecord> {
    const permissionKeys = new Set(accessPermissionCatalog.map((item) => item.key));
    if (input.permissions.some((key) => !permissionKeys.has(key))) {
      throw new IdentityError('unknown_permission', 400);
    }
    const duplicate = [...this.roles.values()].find((item) =>
      item.businessId === identity.businessId && item.name.toLowerCase() === input.name.toLowerCase() && item.id !== input.id);
    if (duplicate) throw new IdentityError('role_name_exists', 409);
    if (input.id) {
      const current = this.roles.get(input.id);
      if (!current || current.businessId !== identity.businessId) throw new IdentityError('role_not_found', 404);
      if (current.system) throw new IdentityError('system_role_immutable', 409);
      if (input.expectedVersion !== undefined && input.expectedVersion !== current.version) {
        throw new IdentityError('role_version_conflict', 409);
      }
      current.name = input.name;
      current.roleType = input.roleType;
      current.permissions = [...new Set(input.permissions)].sort();
      current.version++;
      for (const user of this.users.values()) {
        user.roles = user.roles.map((role) => role.id === current.id ? { id: current.id, name: current.name } : role);
        if (user.roles.some((role) => role.id === current.id)) {
          this.revokeUserSessions(user.id);
        }
      }
      this.recordAudit(identity, 'access.role_updated', {
        role_id: current.id, name: current.name, role_type: current.roleType,
        permissions: current.permissions,
      });
      const { businessId: _businessId, ...saved } = current;
      return structuredClone(saved);
    }
    const created: MemoryRole = {
      id: randomUUID(), businessId: identity.businessId, name: input.name,
      roleType: input.roleType,
      permissions: [...new Set(input.permissions)].sort(), system: false, version: 1,
    };
    this.roles.set(created.id, created);
    this.recordAudit(identity, 'access.role_created', {
      role_id: created.id, name: created.name, role_type: created.roleType,
      permissions: created.permissions,
    });
    const { businessId: _businessId, ...saved } = created;
    return structuredClone(saved);
  }

  async listAccessUsers(identity: AuthIdentity): Promise<AccessUserRecord[]> {
    return [...this.users.values()]
      .filter((item) => item.businessId === identity.businessId)
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((item) => this.publicUser(item));
  }

  async createAccessUser(identity: AuthIdentity, input: CreateAccessUserInput): Promise<CreatedAccessUser> {
    this.validateUserUniqueness(identity.businessId, input.username, input.email);
    const roles = this.resolveRoles(identity.businessId, input.roleIds);
    const activationCode = randomUUID().replaceAll('-', '') + randomUUID().replaceAll('-', '');
    const activationExpiresAt = new Date(Date.now() + 72 * 60 * 60_000).toISOString();
    const created: MemoryUser = {
      id: randomUUID(), businessId: identity.businessId, name: input.name,
      username: input.username, email: input.email ?? null, active: true, activated: false,
      roles, securityVersion: 1, activationCode,
      activationExpiresAt: Date.parse(activationExpiresAt),
    };
    this.users.set(created.id, created);
    this.recordAudit(identity, 'access.user_created', {
      affected_user_id: created.id, name: created.name, username: created.username,
      role_ids: roles.map((role) => role.id),
    });
    return { user: this.publicUser(created), activationCode, activationExpiresAt };
  }

  async updateAccessUser(identity: AuthIdentity, userId: string, input: UpdateAccessUserInput): Promise<AccessUserRecord> {
    const current = this.users.get(userId);
    if (!current || current.businessId !== identity.businessId) throw new IdentityError('user_not_found', 404);
    if (current.remoteOwnerId === identity.ownerId && !input.active) {
      throw new IdentityError('cannot_deactivate_current_owner', 409);
    }
    this.validateUserUniqueness(identity.businessId, input.username, input.email, userId);
    const roles = this.resolveRoles(identity.businessId, input.roleIds);
    if (current.remoteOwnerId && !roles.some((role) => this.roles.get(role.id)?.system)) {
      throw new IdentityError('owner_role_required', 409);
    }
    current.name = input.name;
    current.username = input.username;
    current.email = input.email ?? null;
    current.active = input.active;
    current.roles = roles;
    current.securityVersion++;
    this.revokeUserSessions(current.id);
    this.recordAudit(identity, 'access.user_updated', {
      affected_user_id: current.id, name: current.name,
      username: current.username, active: current.active,
      role_ids: roles.map((role) => role.id),
    });
    return this.publicUser(current);
  }

  async activateAccessUser(input: ActivateAccessUserInput, _requestKey?: string): Promise<void> {
    const user = [...this.users.values()].find((item) =>
      item.businessId === input.businessId && item.username.toLowerCase() === input.username.toLowerCase());
    if (!user || !user.active || user.activated || user.activationCode !== input.activationCode ||
        (user.activationExpiresAt ?? 0) <= Date.now()) {
      throw new IdentityError('activation_invalid_or_expired', 409);
    }
    user.password = input.password;
    user.activated = true;
    delete user.activationCode;
    delete user.activationExpiresAt;
    user.securityVersion++;
    this.recordAudit({
      businessId: input.businessId, deviceId: '', ownerId: null,
      userId: user.id, sessionId: '', permissions: [],
    }, 'access.user_activated', { affected_user_id: user.id });
  }

  async loginAccessUser(input: AccessUserLoginInput, _requestKey?: string): Promise<IssuedIdentity> {
    const user = [...this.users.values()].find((item) =>
      item.businessId === input.businessId && item.username.toLowerCase() === input.username.toLowerCase());
    const device = this.devices.get(input.deviceId);
    if (!user || !user.active || !user.activated || user.password !== input.password ||
        device?.businessId !== input.businessId || device.revokedAt) {
      throw new IdentityError('invalid_credentials', 401);
    }
    const permissions = new Set<string>(['sync:read', 'sync:write']);
    for (const role of user.roles) {
      for (const permission of this.roles.get(role.id)?.permissions ?? []) {
        if (permission !== 'devices:manage') permissions.add(permission);
      }
    }
    const issued = this.issue(input.businessId, input.deviceId, null, user.id, [...permissions]);
    this.recordAudit(issued, 'access.session_login', { affected_user_id: user.id });
    return issued;
  }

  async listSecurityAudit(identity: AuthIdentity, limit: number): Promise<SecurityAuditRecord[]> {
    return this.auditRecords
      .filter((item) => item.businessId === identity.businessId)
      .slice(-limit)
      .reverse()
      .map(({ businessId: _businessId, ...item }) => structuredClone(item));
  }

  async deleteBusiness(input: DeleteBusinessInput, _requestKey?: string): Promise<string> {
    const matches = this.accounts.filter((item) =>
      item.email === input.email.toLowerCase() &&
      item.password === input.password &&
      (input.businessId === undefined || item.businessId === input.businessId));
    if (matches.length !== 1) {
      throw new IdentityError(matches.length > 1 ? 'business_id_required' : 'invalid_credentials', matches.length > 1 ? 409 : 401);
    }
    const businessId = matches[0]!.businessId;
    for (let index = this.accounts.length - 1; index >= 0; index--) {
      if (this.accounts[index]!.businessId === businessId) this.accounts.splice(index, 1);
    }
    for (const [deviceId, device] of this.devices) {
      if (device.businessId === businessId) this.devices.delete(deviceId);
    }
    for (const [token, identity] of this.access) {
      if (identity.businessId === businessId) this.access.delete(token);
    }
    for (const [token, saved] of this.refreshTokens) {
      if (saved.identity.businessId === businessId) this.refreshTokens.delete(token);
    }
    for (const [code, link] of this.links) {
      if (link.businessId === businessId) this.links.delete(code);
    }
    for (const [id, role] of this.roles) if (role.businessId === businessId) this.roles.delete(id);
    for (const [id, user] of this.users) if (user.businessId === businessId) this.users.delete(id);
    for (let index = this.auditRecords.length - 1; index >= 0; index--) {
      if (this.auditRecords[index]!.businessId === businessId) this.auditRecords.splice(index, 1);
    }
    return businessId;
  }

  async close(): Promise<void> {}

  expireLinkCode(code: string): void {
    const link = this.links.get(code);
    if (link) link.expiresAt = 0;
  }

  private issue(
    businessId: string,
    deviceId: string,
    ownerId: string | null,
    userId: string | null,
    permissions: string[],
  ): IssuedIdentity {
    const accessToken = `access-${randomUUID()}-${randomUUID()}`;
    const refreshToken = `refresh-${randomUUID()}-${randomUUID()}`;
    const identity: AuthIdentity = {
      businessId,
      deviceId,
      ownerId,
      userId,
      sessionId: randomUUID(),
      permissions: [...permissions],
    };
    this.access.set(accessToken, identity);
    this.refreshTokens.set(refreshToken, { identity, used: false });
    const user = userId ? this.users.get(userId) : null;
    const roleType = user && user.roles.some((role) =>
      this.roles.get(role.id)?.roleType === 'administrator')
      ? 'administrator' as const
      : user ? 'operational' as const : null;
    const grant = user ? this.offlineGrants.issue({
      business_id: businessId,
      device_id: deviceId,
      principal_id: user.id,
      principal_name: user.name,
      username: user.username,
      role_type: roleType!,
      permissions,
      security_version: user.securityVersion,
    }) : null;
    return {
      ...identity,
      principalName: user?.name ?? null,
      username: user?.username ?? null,
      roleType,
      accessToken, refreshToken,
      accessExpiresAt: new Date(Date.now() + 900_000).toISOString(),
      refreshExpiresAt: new Date(Date.now() + 2_592_000_000).toISOString(),
      offlineGrant: grant?.token ?? null,
      offlineGrantPublicKey: grant?.publicKey ?? null,
      offlineGrantExpiresAt: grant?.expiresAt ?? null,
    };
  }

  private resolveRoles(businessId: string, roleIds: string[]): Array<{ id: string; name: string }> {
    const unique = [...new Set(roleIds)];
    const roles = unique.map((id) => this.roles.get(id));
    if (roles.some((role) => !role || role.businessId !== businessId)) throw new IdentityError('role_not_found', 404);
    return roles.map((role) => ({ id: role!.id, name: role!.name }));
  }

  private recordAudit(
    identity: AuthIdentity,
    event: string,
    details: Record<string, unknown>,
  ): void {
    const user = identity.userId ? this.users.get(identity.userId) : null;
    const owner = identity.ownerId
      ? this.accounts.find((item) => item.ownerId === identity.ownerId)
      : null;
    const device = identity.deviceId ? this.devices.get(identity.deviceId) : null;
    this.auditRecords.push({
      businessId: identity.businessId,
      id: String(this.auditRecords.length + 1),
      event,
      deviceId: identity.deviceId || null,
      ownerId: identity.ownerId,
      userId: identity.userId,
      actorName: user?.name ?? owner?.email ?? 'Sistema',
      deviceName: device?.name ?? null,
      details: structuredClone(details),
      createdAt: new Date().toISOString(),
    });
  }

  private publicUser(user: MemoryUser): AccessUserRecord {
    return structuredClone({
      id: user.id,
      name: user.name,
      username: user.username,
      email: user.email,
      active: user.active,
      activated: user.activated,
      roles: user.roles,
      securityVersion: user.securityVersion,
    });
  }

  private validateUserUniqueness(businessId: string, username: string, email?: string, exceptId?: string): void {
    const conflict = [...this.users.values()].find((user) =>
      user.businessId === businessId && user.id !== exceptId &&
      (user.username.toLowerCase() === username.toLowerCase() ||
       (email !== undefined && user.email?.toLowerCase() === email.toLowerCase())));
    if (conflict) throw new IdentityError('user_identity_exists', 409);
  }

  private revokeUserSessions(userId: string): void {
    for (const [token, identity] of this.access) {
      if (identity.userId === userId) this.access.delete(token);
    }
    for (const [token, saved] of this.refreshTokens) {
      if (saved.identity.userId === userId) this.refreshTokens.delete(token);
    }
  }

  private device(input: { deviceId: string; deviceName: string; platform: string }, businessId: string): DeviceRecord & { businessId: string } {
    return { id: input.deviceId, name: input.deviceName, platform: input.platform, businessId, createdAt: new Date().toISOString(), lastSeenAt: null, revokedAt: null, current: false };
  }
}
