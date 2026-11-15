# Scripts históricos fuera de la secuencia activa

Estos archivos se conservan como referencia; Supabase CLI no debe ejecutarlos.
Sus versiones `0004` y `0005` colisionaban con migraciones distintas ya registradas
en el proyecto Cloud `integracion3`.

El esquema vigente de `0001` ya incluye `usuarios.auth_user_id` y
`configuracion_telegram_dueno`; `0007` contiene las políticas actuales. Reaplicar
los scripts antiguos duplicaría columnas o sustituiría permisos por reglas anteriores.
No se han eliminado sus contenidos ni se ha modificado el historial remoto.

La carpeta `../migrations` reproduce las versiones consultadas en Cloud: `0008`
repite Realtime, `0009` repite RLS y `0010` crea solicitudes de stock. Esas
repeticiones forman parte del historial aplicado y se conservan intencionalmente.
