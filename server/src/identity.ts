export const ownerPermissions = [
  'sync:read',
  'sync:write',
  'devices:read',
  'devices:manage',
  'access:read',
  'access:manage',
] as const;

export interface AccessPermissionRecord {
  key: string;
  module: string;
  action: string;
  description: string;
}

export const accessPermissionCatalog: AccessPermissionRecord[] = [
  ['productos.ver', 'productos', 'ver', 'Consultar productos'],
  ['productos.crear', 'productos', 'crear', 'Crear productos'],
  ['productos.editar', 'productos', 'editar', 'Editar productos'],
  ['productos.eliminar', 'productos', 'eliminar', 'Eliminar productos'],
  ['ventas.ver', 'ventas', 'ver', 'Consultar ventas'],
  ['ventas.crear', 'ventas', 'crear', 'Crear ventas'],
  ['ventas.editar', 'ventas', 'editar', 'Editar ventas'],
  ['ventas.anular', 'ventas', 'anular', 'Anular ventas'],
  ['inventario.ver', 'inventario', 'ver', 'Consultar inventario'],
  ['inventario.ajustar', 'inventario', 'ajustar', 'Ajustar inventario'],
  ['usuarios.ver', 'usuarios', 'ver', 'Consultar usuarios'],
  ['usuarios.crear', 'usuarios', 'crear', 'Crear usuarios'],
  ['usuarios.editar', 'usuarios', 'editar', 'Editar usuarios'],
  ['usuarios.eliminar', 'usuarios', 'eliminar', 'Desactivar usuarios'],
  ['roles.ver', 'roles', 'ver', 'Consultar roles'],
  ['roles.crear', 'roles', 'crear', 'Crear roles'],
  ['roles.editar', 'roles', 'editar', 'Editar roles'],
  ['roles.eliminar', 'roles', 'eliminar', 'Eliminar roles'],
  ['configuracion.ver', 'configuracion', 'ver', 'Consultar configuración'],
  ['configuracion.editar', 'configuracion', 'editar', 'Editar configuración'],
  ['reportes.ver', 'reportes', 'ver', 'Consultar reportes'],
  ['auditoria.ver', 'auditoria', 'ver', 'Consultar auditoría'],
  ['clientes.ver', 'clientes', 'ver', 'Consultar clientes'],
  ['clientes.crear', 'clientes', 'crear', 'Crear clientes'],
  ['clientes.editar', 'clientes', 'editar', 'Editar clientes'],
  ['clientes.eliminar', 'clientes', 'eliminar', 'Eliminar clientes'],
  ['proveedores.ver', 'proveedores', 'ver', 'Consultar proveedores'],
  ['proveedores.crear', 'proveedores', 'crear', 'Crear proveedores'],
  ['proveedores.editar', 'proveedores', 'editar', 'Editar proveedores'],
  ['proveedores.eliminar', 'proveedores', 'eliminar', 'Eliminar proveedores'],
  ['compras.ver', 'compras', 'ver', 'Consultar compras'],
  ['compras.crear', 'compras', 'crear', 'Crear compras'],
  ['compras.editar', 'compras', 'editar', 'Editar compras'],
  ['compras.recibir', 'compras', 'recibir', 'Recibir compras'],
  ['compras.abonar', 'compras', 'abonar', 'Registrar pagos de compras'],
  ['cotizaciones.ver', 'cotizaciones', 'ver', 'Consultar cotizaciones'],
  ['cotizaciones.crear', 'cotizaciones', 'crear', 'Crear cotizaciones'],
  ['cotizaciones.editar', 'cotizaciones', 'editar', 'Editar cotizaciones'],
  ['cotizaciones.convertir', 'cotizaciones', 'convertir', 'Convertir cotizaciones en ventas'],
  ['trabajos.ver', 'trabajos', 'ver', 'Consultar trabajos'],
  ['trabajos.crear', 'trabajos', 'crear', 'Crear trabajos'],
  ['trabajos.editar', 'trabajos', 'editar', 'Editar trabajos'],
  ['trabajos.cobrar', 'trabajos', 'cobrar', 'Cobrar trabajos'],
  ['caja.ver', 'caja', 'ver', 'Consultar caja'],
  ['caja.abrir', 'caja', 'abrir', 'Abrir caja'],
  ['caja.cerrar', 'caja', 'cerrar', 'Cerrar caja'],
  ['caja.movimientos', 'caja', 'movimientos', 'Registrar movimientos de caja'],
  ['gastos.crear', 'gastos', 'crear', 'Registrar gastos'],
  ['devoluciones.crear', 'devoluciones', 'crear', 'Registrar devoluciones'],
  ['precios.editar', 'precios', 'editar', 'Modificar precios durante operaciones'],
  ['respaldos.crear', 'respaldos', 'crear', 'Crear respaldos'],
  ['respaldos.restaurar', 'respaldos', 'restaurar', 'Restaurar respaldos'],
  ['conflictos.ver', 'conflictos', 'ver', 'Consultar conflictos de sincronización'],
  ['conflictos.resolver', 'conflictos', 'resolver', 'Marcar conflictos revisados'],
  ['sync:read', 'sistema', 'sync_read', 'Descargar cambios del negocio'],
  ['sync:write', 'sistema', 'sync_write', 'Enviar cambios del dispositivo'],
  ['devices:read', 'sistema', 'devices_read', 'Consultar dispositivos'],
  ['devices:manage', 'sistema', 'devices_manage', 'Administrar dispositivos'],
  ['access:read', 'sistema', 'access_read', 'Consultar control de acceso'],
  ['access:manage', 'sistema', 'access_manage', 'Administrar control de acceso'],
].map(([key, module, action, description]) => ({
  key: key!,
  module: module!,
  action: action!,
  description: description!,
}));

export interface AccessRoleRecord {
  id: string;
  name: string;
  roleType: 'administrator' | 'operational';
  permissions: string[];
  system: boolean;
  version: number;
}

export interface AccessUserRecord {
  id: string;
  name: string;
  username: string;
  email: string | null;
  active: boolean;
  activated: boolean;
  roles: Array<{ id: string; name: string }>;
  securityVersion: number;
}

export interface SaveAccessRoleInput {
  id?: string;
  name: string;
  roleType: 'administrator' | 'operational';
  permissions: string[];
  expectedVersion?: number;
}

export interface CreateAccessUserInput {
  name: string;
  username: string;
  email?: string;
  roleIds: string[];
}

export interface ActivateAccessUserInput {
  businessId: string;
  username: string;
  activationCode: string;
  password: string;
}

export interface AccessUserLoginInput {
  businessId: string;
  username: string;
  password: string;
  deviceId: string;
}

export interface UpdateAccessUserInput {
  name: string;
  username: string;
  email?: string;
  active: boolean;
  roleIds: string[];
}

export interface CreatedAccessUser {
  user: AccessUserRecord;
  activationCode: string;
  activationExpiresAt: string;
}

export interface AuthIdentity {
  businessId: string;
  deviceId: string;
  ownerId: string | null;
  userId: string | null;
  sessionId: string;
  permissions: string[];
}

export interface IssuedIdentity extends AuthIdentity {
  principalName: string | null;
  username: string | null;
  roleType: 'administrator' | 'operational' | null;
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: string;
  refreshExpiresAt: string;
  offlineGrant: string | null;
  offlineGrantPublicKey: string | null;
  offlineGrantExpiresAt: string | null;
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

export interface SecurityAuditRecord {
  id: string;
  event: string;
  deviceId: string | null;
  ownerId: string | null;
  userId: string | null;
  actorName: string;
  deviceName: string | null;
  details: Record<string, unknown>;
  createdAt: string;
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
  listAccessPermissions(identity: AuthIdentity): Promise<AccessPermissionRecord[]>;
  listAccessRoles(identity: AuthIdentity): Promise<AccessRoleRecord[]>;
  saveAccessRole(identity: AuthIdentity, input: SaveAccessRoleInput): Promise<AccessRoleRecord>;
  listAccessUsers(identity: AuthIdentity): Promise<AccessUserRecord[]>;
  createAccessUser(identity: AuthIdentity, input: CreateAccessUserInput): Promise<CreatedAccessUser>;
  updateAccessUser(identity: AuthIdentity, userId: string, input: UpdateAccessUserInput): Promise<AccessUserRecord>;
  activateAccessUser(input: ActivateAccessUserInput, requestKey: string): Promise<void>;
  loginAccessUser(input: AccessUserLoginInput, requestKey: string): Promise<IssuedIdentity>;
  listSecurityAudit(identity: AuthIdentity, limit: number): Promise<SecurityAuditRecord[]>;
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

export function requireAnyPermission(
  identity: AuthIdentity,
  permissions: readonly string[],
): void {
  if (!permissions.some((permission) => identity.permissions.includes(permission))) {
    throw new IdentityError('forbidden', 403);
  }
}
