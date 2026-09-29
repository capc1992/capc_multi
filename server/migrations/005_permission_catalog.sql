BEGIN;

INSERT INTO access_permissions (key,module,action,description) VALUES
  ('clientes.ver','clientes','ver','Consultar clientes'),
  ('clientes.crear','clientes','crear','Crear clientes'),
  ('clientes.editar','clientes','editar','Editar clientes'),
  ('clientes.eliminar','clientes','eliminar','Eliminar clientes'),
  ('proveedores.ver','proveedores','ver','Consultar proveedores'),
  ('proveedores.crear','proveedores','crear','Crear proveedores'),
  ('proveedores.editar','proveedores','editar','Editar proveedores'),
  ('proveedores.eliminar','proveedores','eliminar','Eliminar proveedores'),
  ('compras.ver','compras','ver','Consultar compras'),
  ('compras.crear','compras','crear','Crear compras'),
  ('compras.editar','compras','editar','Editar compras'),
  ('compras.recibir','compras','recibir','Recibir compras'),
  ('compras.abonar','compras','abonar','Registrar pagos de compras'),
  ('cotizaciones.ver','cotizaciones','ver','Consultar cotizaciones'),
  ('cotizaciones.crear','cotizaciones','crear','Crear cotizaciones'),
  ('cotizaciones.editar','cotizaciones','editar','Editar cotizaciones'),
  ('cotizaciones.convertir','cotizaciones','convertir','Convertir cotizaciones en ventas'),
  ('trabajos.ver','trabajos','ver','Consultar trabajos'),
  ('trabajos.crear','trabajos','crear','Crear trabajos'),
  ('trabajos.editar','trabajos','editar','Editar trabajos'),
  ('trabajos.cobrar','trabajos','cobrar','Cobrar trabajos'),
  ('caja.ver','caja','ver','Consultar caja'),
  ('caja.abrir','caja','abrir','Abrir caja'),
  ('caja.cerrar','caja','cerrar','Cerrar caja'),
  ('caja.movimientos','caja','movimientos','Registrar movimientos de caja'),
  ('gastos.crear','gastos','crear','Registrar gastos'),
  ('devoluciones.crear','devoluciones','crear','Registrar devoluciones'),
  ('precios.editar','precios','editar','Modificar precios durante operaciones'),
  ('respaldos.crear','respaldos','crear','Crear respaldos'),
  ('respaldos.restaurar','respaldos','restaurar','Restaurar respaldos'),
  ('conflictos.ver','conflictos','ver','Consultar conflictos de sincronización'),
  ('conflictos.resolver','conflictos','resolver','Marcar conflictos revisados')
ON CONFLICT (key) DO NOTHING;

INSERT INTO access_role_permissions (role_id,permission_key)
SELECT r.id,p.key FROM access_roles r CROSS JOIN access_permissions p
WHERE r.is_system=true AND r.name='Administrador principal'
ON CONFLICT DO NOTHING;

COMMIT;
