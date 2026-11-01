# Validación Offline-First y multiusuario

Esta matriz separa la evidencia automatizada disponible de las comprobaciones que requieren PostgreSQL real o equipos físicos. Todas las pruebas locales usan bases temporales y datos ficticios.

| Escenario requerido | Cobertura automatizada | Estado local |
| --- | --- | --- |
| Escritorio con Internet | motor push/pull, autenticación y UI de sincronización | Aprobado |
| Escritorio sin Internet | SQLite, outbox y estado `localOnly` | Aprobado |
| Móvil con Internet | mismo repositorio/transporte y flujo Android | Aprobado en pruebas Flutter |
| Móvil sin Internet | persistencia y respaldo Android sin red | Aprobado en pruebas Flutter |
| Cambio offline y reconexión | mutación y outbox atómicas, push posterior | Aprobado |
| Dos equipos modifican registros distintos | convergencia entre dos SQLite | Aprobado |
| Dos equipos modifican el mismo registro | revisión optimista y conflicto durable | Aprobado |
| Creación offline | UUID generado localmente e idempotencia por `operation_id` | Aprobado |
| Eliminación offline | tombstones de producto, cliente y proveedor | Aprobado |
| Equipo varios días desconectado | cursor incremental y concesión offline con vencimiento | Aprobado por lógica; requiere piloto prolongado |
| Cierre antes de sincronizar | outbox persistente y reapertura de SQLite | Aprobado |
| Error del servidor | reintentos, `last_error` y operación pendiente | Aprobado |
| Corte durante sincronización | respuesta perdida y reenvío idempotente | Aprobado |
| Acción sin permiso | repositorio, API y UI verifican permisos granulares | Aprobado |
| Cambio de permisos con otro equipo offline | `security_version`, renovación conectada y concesión máxima de 72 h | Aprobado por lógica; requiere piloto temporal |
| Dos documentos con el mismo consecutivo offline | UUID intacto, sufijo estable y secuencia local reasignada | Aprobado |
| Conflicto revisado | bandeja protegida y `resolved_at` durable sin borrar evidencia | Aprobado |
| Auditoría central | seguridad más eventos de negocio por usuario/dispositivo | Aprobado en memoria; preparado para PostgreSQL |

## Comandos de verificación

```powershell
flutter analyze --no-pub
flutter test --no-pub -r expanded
python -m unittest discover -s tools -p "test_*.py"
cd server
npm run check
npm test
npm run build
```

Con `DATABASE_URL` apuntando a una instancia PostgreSQL 16 desechable, `npm test` habilita ocho pruebas adicionales. El workflow `Cloud Sync Identity` crea ese servicio, aplica las migraciones dos veces, prueba integración, ejecuta la reversa, verifica el esquema y vuelve a migrar.

Las compilaciones locales verificadas son `build/windows/x64/runner/Release/capc_multi.exe` y `build/app/outputs/flutter-apk/app-debug.apk`. El APK es de depuración y no es publicable. Gradle avisó que `package_info_plus` todavía aplica Kotlin Gradle Plugin y deberá migrarse antes de que una versión futura de Flutter lo convierta en error; la compilación actual terminó correctamente.

## Criterios del piloto

El piloto debe usar un entorno separado y datos ficticios, dos equipos Windows y un Android. Debe incluir al menos 72 horas de desconexión simulada, cambio de permisos durante la desconexión, reloj incorrecto, corte de red durante push y pull, restauración desde respaldo, revisión de conflictos y cotejo de auditoría. La aprobación del piloto exige cero pérdida de IDs/eventos, saldos explicables por movimientos y aislamiento total entre dos `business_id`.
