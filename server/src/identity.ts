export const ownerPermissions = [
  'sync:read',
  'sync:write',
  'devices:read',
  'devices:manage',
] as const;

export interface AuthIdentity {
  businessId: string;
  deviceId: string;
  ownerId: string;
  sessionId: string;
  permissions: string[];
}

export interface IssuedIdentity extends AuthIdentity {
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: string;
  refreshExpiresAt: string;
}

export interface DeviceRecord {
  id: string;
  name: string;
  platform: string;
  createdAt: string;
  lastSeenAt: string | null;
  revokedAt: string | null;
  current: boolean;
}

export interface CreateBusinessInput {
  businessId: string;
  businessName: string;
  email: string;
  password: string;
  deviceId: string;
  deviceName: string;
  platform: string;
}

export interface LoginInput {
  businessId: string;
  email: string;
  password: string;
  deviceId: string;
}

export interface DeleteBusinessInput {
  businessId?: string;
  email: string;
  password: string;
}

export interface LinkDeviceInput {
  code: string;
  deviceId: string;
  deviceName: string;
  platform: string;
  localBusinessId: string;
  localState: 'new' | 'no_movements';
}

export interface IdentityStore {
  createBusiness(input: CreateBusinessInput, requestKey: string): Promise<IssuedIdentity>;
  login(input: LoginInput, requestKey: string): Promise<IssuedIdentity>;
  refresh(refreshToken: string, deviceId: string, requestKey: string): Promise<IssuedIdentity>;
  authenticate(accessToken: string): Promise<AuthIdentity | null>;
  createLinkCode(identity: AuthIdentity): Promise<{ code: string; expiresAt: string }>;
  linkDevice(input: LinkDeviceInput, requestKey: string): Promise<IssuedIdentity>;
  listDevices(identity: AuthIdentity): Promise<DeviceRecord[]>;
  revokeDevice(identity: AuthIdentity, deviceId: string): Promise<void>;
  logout(identity: AuthIdentity): Promise<void>;
  deleteBusiness(input: DeleteBusinessInput, requestKey: string): Promise<string>;
  close(): Promise<void>;
}

export class IdentityError extends Error {
  constructor(
    readonly code: string,
    readonly statusCode: number,
  ) {
    super(code);
  }
}

export function requirePermission(identity: AuthIdentity, permission: string): void {
  if (!identity.permissions.includes(permission)) {
    throw new IdentityError('insufficient_permission', 403);
  }
}
