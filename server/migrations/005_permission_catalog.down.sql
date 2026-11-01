BEGIN;

DELETE FROM access_role_permissions WHERE permission_key IN (
  'clientes.ver','clientes.crear','clientes.editar','clientes.eliminar',
  'proveedores.ver','proveedores.crear','proveedores.editar','proveedores.eliminar',
  'compras.ver','compras.crear','compras.editar','compras.recibir','compras.abonar',
  'cotizaciones.ver','cotizaciones.crear','cotizaciones.editar','cotizaciones.convertir',
  'trabajos.ver','trabajos.crear','trabajos.editar','trabajos.cobrar',
  'caja.ver','caja.abrir','caja.cerrar','caja.movimientos','gastos.crear',
  'devoluciones.crear','precios.editar','respaldos.crear','respaldos.restaurar',
  'conflictos.ver','conflictos.resolver'
);
DELETE FROM access_permissions WHERE key IN (
  'clientes.ver','clientes.crear','clientes.editar','clientes.eliminar',
  'proveedores.ver','proveedores.crear','proveedores.editar','proveedores.eliminar',
  'compras.ver','compras.crear','compras.editar','compras.recibir','compras.abonar',
  'cotizaciones.ver','cotizaciones.crear','cotizaciones.editar','cotizaciones.convertir',
  'trabajos.ver','trabajos.crear','trabajos.editar','trabajos.cobrar',
  'caja.ver','caja.abrir','caja.cerrar','caja.movimientos','gastos.crear',
  'devoluciones.crear','precios.editar','respaldos.crear','respaldos.restaurar',
  'conflictos.ver','conflictos.resolver'
);

COMMIT;
