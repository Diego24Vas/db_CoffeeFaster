-- ============================================================================
-- MIGRACIÓN: CONFIGURACIÓN EXCLUSIVA DE TELEGRAM PARA EL ROL DE DUEÑO
-- ============================================================================
-- Cumple con: FR-18, FR-19, BR-06, CA-FR-11
-- Restricción estricta de roles: Administración y alertas exclusivas para el Dueño.
-- Los roles de estudiante y empleado NO tienen acceso a esta tabla ni a sus alertas.
-- ============================================================================

-- ==========================================
-- PASO 1: CREAR TABLA CONFIGURACION_TELEGRAM_DUENO
-- ==========================================

CREATE TABLE IF NOT EXISTS configuracion_telegram_dueno (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT UNIQUE NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    cafeteria_id BIGINT NOT NULL REFERENCES cafeterias(id) ON DELETE CASCADE,
    telegram_chat_id BIGINT UNIQUE NOT NULL,
    notificaciones_activas BOOLEAN DEFAULT true,
    creado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Índices de búsqueda y rendimiento
CREATE INDEX IF NOT EXISTS idx_cfg_telegram_usuario ON configuracion_telegram_dueno(usuario_id);
CREATE INDEX IF NOT EXISTS idx_cfg_telegram_chat_id ON configuracion_telegram_dueno(telegram_chat_id);
CREATE INDEX IF NOT EXISTS idx_cfg_telegram_cafeteria ON configuracion_telegram_dueno(cafeteria_id);

COMMENT ON TABLE configuracion_telegram_dueno IS 
    'Almacena exclusivamente los identificadores de Telegram y preferencias del Dueño de Cafetería (BR-06). Inaccesible para estudiantes y empleados.';

-- ==========================================
-- PASO 2: TRIGGER DE VALIDACIÓN DE ROL DUEÑO
-- ==========================================
-- Impide a nivel de base de datos que cualquier usuario con rol diferente a 'dueño'
-- pueda ser insertado o asociado en esta tabla (integridad de negocio BR-06).

CREATE OR REPLACE FUNCTION validar_rol_dueno_telegram()
RETURNS TRIGGER AS $$
DECLARE
    v_rol_nombre VARCHAR;
BEGIN
    SELECT r.nombre INTO v_rol_nombre
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.id = NEW.usuario_id;

    IF v_rol_nombre IS DISTINCT FROM 'dueño' THEN
        RAISE EXCEPTION 'Operación rechazada: Solo usuarios con rol dueño pueden tener configuración de Telegram (BR-06). Rol detectado: %', v_rol_nombre;
    END IF;

    -- Validar que el dueño pertenezca a la cafetería indicada
    IF NOT EXISTS (
        SELECT 1 FROM cafeteria_usuarios cu
        WHERE cu.usuario_id = NEW.usuario_id
        AND cu.cafeteria_id = NEW.cafeteria_id
    ) THEN
        -- Si no existe la asignación previa, la registramos automáticamente para mantener consistencia
        INSERT INTO cafeteria_usuarios (usuario_id, cafeteria_id, cargo, gestiona_inventario, gestiona_productos)
        VALUES (NEW.usuario_id, NEW.cafeteria_id, 'Dueño / Administrador', true, true)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS tr_validar_dueno_telegram ON configuracion_telegram_dueno;
CREATE TRIGGER tr_validar_dueno_telegram
    BEFORE INSERT OR UPDATE ON configuracion_telegram_dueno
    FOR EACH ROW
    EXECUTE FUNCTION validar_rol_dueno_telegram();

-- ==========================================
-- PASO 3: POLÍTICAS DE ROW LEVEL SECURITY (RLS)
-- ==========================================
-- Asegura que solo el usuario con rol 'dueño' pueda interactuar con su registro de Telegram.
-- Para estudiantes y empleados no hay acceso alguno.

ALTER TABLE configuracion_telegram_dueno ENABLE ROW LEVEL SECURITY;

-- 1. SELECT: Solo el dueño puede ver su propia configuración
DROP POLICY IF EXISTS "telegram_dueno_select_own" ON configuracion_telegram_dueno;
CREATE POLICY "telegram_dueno_select_own" ON configuracion_telegram_dueno
    FOR SELECT USING (
        (is_dueno() AND usuario_id = (SELECT id FROM usuarios WHERE auth_user_id = auth.uid()))
        OR
        (auth.uid() IS NULL AND EXISTS (
            SELECT 1 FROM usuarios u 
            JOIN roles r ON r.id = u.rol_id 
            WHERE u.id = configuracion_telegram_dueno.usuario_id 
            AND r.nombre = 'dueño'
        ))
    );

-- 2. INSERT: Solo el dueño puede insertar su propia configuración
DROP POLICY IF EXISTS "telegram_dueno_insert_own" ON configuracion_telegram_dueno;
CREATE POLICY "telegram_dueno_insert_own" ON configuracion_telegram_dueno
    FOR INSERT WITH CHECK (
        (is_dueno() AND usuario_id = (SELECT id FROM usuarios WHERE auth_user_id = auth.uid()))
        OR
        (auth.uid() IS NULL AND EXISTS (
            SELECT 1 FROM usuarios u 
            JOIN roles r ON r.id = u.rol_id 
            WHERE u.id = configuracion_telegram_dueno.usuario_id 
            AND r.nombre = 'dueño'
        ))
    );

-- 3. UPDATE: Solo el dueño puede actualizar su propia configuración
DROP POLICY IF EXISTS "telegram_dueno_update_own" ON configuracion_telegram_dueno;
CREATE POLICY "telegram_dueno_update_own" ON configuracion_telegram_dueno
    FOR UPDATE USING (
        (is_dueno() AND usuario_id = (SELECT id FROM usuarios WHERE auth_user_id = auth.uid()))
        OR
        (auth.uid() IS NULL AND EXISTS (
            SELECT 1 FROM usuarios u 
            JOIN roles r ON r.id = u.rol_id 
            WHERE u.id = configuracion_telegram_dueno.usuario_id 
            AND r.nombre = 'dueño'
        ))
    ) WITH CHECK (
        (is_dueno() AND usuario_id = (SELECT id FROM usuarios WHERE auth_user_id = auth.uid()))
        OR
        (auth.uid() IS NULL AND EXISTS (
            SELECT 1 FROM usuarios u 
            JOIN roles r ON r.id = u.rol_id 
            WHERE u.id = configuracion_telegram_dueno.usuario_id 
            AND r.nombre = 'dueño'
        ))
    );

-- 4. DELETE: Solo el dueño puede desvincular su configuración
DROP POLICY IF EXISTS "telegram_dueno_delete_own" ON configuracion_telegram_dueno;
CREATE POLICY "telegram_dueno_delete_own" ON configuracion_telegram_dueno
    FOR DELETE USING (
        (is_dueno() AND usuario_id = (SELECT id FROM usuarios WHERE auth_user_id = auth.uid()))
        OR
        (auth.uid() IS NULL AND EXISTS (
            SELECT 1 FROM usuarios u 
            JOIN roles r ON r.id = u.rol_id 
            WHERE u.id = configuracion_telegram_dueno.usuario_id 
            AND r.nombre = 'dueño'
        ))
    );


-- ==========================================
-- PASO 4: FUNCIÓN DE ALERTA DE STOCK BAJO DIRIGIDA AL DUEÑO (FR-19, BR-06)
-- ==========================================
-- Evalúa el stock tras cada venta/actualización en 'productos' con lógica antispam:
-- OLD.stock > 10 AND NEW.stock <= 10.
-- Busca el dueño de la cafetería específica y envía el webhook con el destinatario exacto.

CREATE OR REPLACE FUNCTION notificar_stock_bajo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    v_umbral CONSTANT INTEGER := 10;
    v_chat_id BIGINT;
    v_dueno_nombre VARCHAR;
    v_payload JSONB;
BEGIN
    -- Lógica: Disparar si cruza umbral de stock bajo (> 10 a <= 10) O se agota completamente (> 0 a <= 0)
    IF OLD.stock IS NOT NULL 
       AND NEW.stock IS NOT NULL 
       AND (
           (OLD.stock > v_umbral AND NEW.stock <= v_umbral)
           OR (OLD.stock > 0 AND NEW.stock <= 0)
       ) THEN

        -- 1. Buscar el chat_id del Dueño configurado para la cafetería del producto
        SELECT ctd.telegram_chat_id, u.nombre 
        INTO v_chat_id, v_dueno_nombre
        FROM configuracion_telegram_dueno ctd
        JOIN usuarios u ON u.id = ctd.usuario_id
        WHERE ctd.cafeteria_id = NEW.cafeteria_id
          AND ctd.notificaciones_activas = true
        LIMIT 1;

        -- 2. Registrar siempre la alerta en la tabla oficial alertas_stock
        INSERT INTO alertas_stock (
            cafeteria_id,
            producto_id,
            stock_actual,
            stock_minimo,
            mensaje,
            leida
        ) VALUES (
            NEW.cafeteria_id,
            NEW.id,
            NEW.stock,
            NEW.stock_minimo,
            CASE 
                WHEN NEW.stock <= 0 THEN 'Producto ''' || NEW.nombre || ''' sin stock (0 unidades disponibles)'
                ELSE 'Stock de ''' || NEW.nombre || ''' bajo a ' || NEW.stock || ' un. (umbral: ' || v_umbral || ')'
            END,
            false
        );

        -- 3. Si existe un dueño vinculado y con notificaciones activas, despachar Webhook
        IF v_chat_id IS NOT NULL THEN
            v_payload := jsonb_build_object(
                'evento', CASE WHEN NEW.stock <= 0 THEN 'ALERTA_SIN_STOCK' ELSE 'ALERTA_STOCK_BAJO' END,
                'destinatario_chat_id', v_chat_id,
                'dueno_nombre', v_dueno_nombre,
                'producto', jsonb_build_object(
                    'id', NEW.id,
                    'nombre', NEW.nombre,
                    'stock_actual', NEW.stock,
                    'stock_anterior', OLD.stock,
                    'stock_minimo_configurado', NEW.stock_minimo,
                    'cafeteria_id', NEW.cafeteria_id
                ),
                'umbral_disparo', v_umbral,
                'timestamp', timezone('utc', clock_timestamp())
            );

            -- Envío asíncrono con tolerancia a fallos mediante pg_net
            BEGIN
                PERFORM net.http_post(
                    url := 'http://host.docker.internal:8000/webhook/stock-alerta',
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'User-Agent', 'Supabase-pg_net-StockNotifier/1.0'
                    ),
                    body := v_payload,
                    timeout_milliseconds := 5000
                );
            EXCEPTION WHEN OTHERS THEN
                -- Si pg_net no está activo o hay falla de red, la transacción de venta no se aborta
                NULL;
            END;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notificar_stock_bajo IS 
    'Dispara alertas automáticas dirigidas exclusivamente al Dueño vinculado de la cafetería cuando el stock cae a 10 o menos unidades (FR-19, BR-06).';

-- ==========================================
-- PASO 5: ACTIVAR TRIGGER EN TABLA PRODUCTOS
-- ==========================================

DROP TRIGGER IF EXISTS tr_alerta_stock_bajo ON productos;
CREATE TRIGGER tr_alerta_stock_bajo
    AFTER UPDATE OF stock ON productos
    FOR EACH ROW
    EXECUTE FUNCTION notificar_stock_bajo();

-- ==========================================
-- PASO 6: FUNCIONES SEGURAS DE CONSULTA PARA TELEGRAM (PROTECCIÓN CONTRA ACCESO GLOBAL)
-- ==========================================

CREATE OR REPLACE FUNCTION verificar_dueno_telegram(p_chat_id BIGINT)
RETURNS TABLE (
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR,
    dueno_id BIGINT,
    dueno_nombre VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ctd.cafeteria_id,
        c.nombre AS cafeteria_nombre,
        u.id AS dueno_id,
        u.nombre AS dueno_nombre
    FROM configuracion_telegram_dueno ctd
    JOIN cafeterias c ON c.id = ctd.cafeteria_id
    JOIN usuarios u ON u.id = ctd.usuario_id
    WHERE ctd.telegram_chat_id = p_chat_id
      AND ctd.notificaciones_activas = true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION obtener_stock_bajo_dueno(
    p_chat_id BIGINT,
    p_umbral INTEGER DEFAULT 10
)
RETURNS TABLE (
    id BIGINT,
    nombre VARCHAR,
    stock INTEGER,
    stock_minimo INTEGER,
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR
) AS $$
BEGIN
    -- Si el chat_id NO está vinculado o fue desvinculado, retorna VACÍO (bloqueo total)
    IF NOT EXISTS (
        SELECT 1 FROM configuracion_telegram_dueno
        WHERE telegram_chat_id = p_chat_id
          AND notificaciones_activas = true
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT 
        p.id,
        p.nombre,
        p.stock,
        p.stock_minimo,
        p.cafeteria_id,
        c.nombre AS cafeteria_nombre
    FROM productos p
    JOIN cafeterias c ON c.id = p.cafeteria_id
    JOIN configuracion_telegram_dueno ctd ON ctd.cafeteria_id = p.cafeteria_id
    WHERE ctd.telegram_chat_id = p_chat_id
      AND p.cafeteria_id = ctd.cafeteria_id
      AND (p.stock <= p.stock_minimo OR p.stock <= p_umbral)
      AND (p.activo = true OR p.activo IS NULL)
      AND p.eliminado_en IS NULL
    ORDER BY p.stock ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS obtener_alertas_dueno(BIGINT, INTEGER);
CREATE OR REPLACE FUNCTION obtener_alertas_dueno(
    p_chat_id BIGINT,
    p_limite INTEGER DEFAULT 5
)
RETURNS TABLE (
    id BIGINT,
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR,
    dueno_id BIGINT,
    dueno_nombre VARCHAR,
    producto_id BIGINT,
    producto_nombre VARCHAR,
    stock_actual INTEGER,
    stock_minimo INTEGER,
    mensaje TEXT,
    leida BOOLEAN,
    creado_en TIMESTAMP
) AS $$
BEGIN
    -- Si el chat_id NO está vinculado o fue desvinculado, retorna VACÍO (bloqueo total)
    IF NOT EXISTS (
        SELECT 1 FROM configuracion_telegram_dueno
        WHERE telegram_chat_id = p_chat_id
          AND notificaciones_activas = true
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH ultimas_alertas AS (
        SELECT DISTINCT ON (a.producto_id)
            a.id,
            a.cafeteria_id,
            c.nombre AS cafeteria_nombre,
            u.id AS dueno_id,
            u.nombre AS dueno_nombre,
            a.producto_id,
            p.nombre::VARCHAR AS producto_nombre,
            p.stock AS stock_actual,
            p.stock_minimo,
            a.mensaje,
            a.leida,
            a.creado_en
        FROM alertas_stock a
        JOIN cafeterias c ON c.id = a.cafeteria_id
        JOIN configuracion_telegram_dueno ctd ON ctd.cafeteria_id = a.cafeteria_id
        JOIN usuarios u ON u.id = ctd.usuario_id
        JOIN productos p ON p.id = a.producto_id
        WHERE ctd.telegram_chat_id = p_chat_id
          AND (a.usuario_id IS NULL OR a.usuario_id = ctd.usuario_id)
          AND p.cafeteria_id = ctd.cafeteria_id
          AND (p.activo = true OR p.activo IS NULL)
          AND p.eliminado_en IS NULL
        ORDER BY a.producto_id, a.creado_en DESC
    )
    SELECT * FROM ultimas_alertas
    ORDER BY creado_en DESC
    LIMIT p_limite;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================
-- PASO 7: PERMISOS Y PRIVILEGIOS
-- ==========================================

GRANT SELECT, INSERT, UPDATE, DELETE ON configuracion_telegram_dueno TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE configuracion_telegram_dueno_id_seq TO authenticated;
GRANT EXECUTE ON FUNCTION verificar_dueno_telegram(BIGINT) TO authenticated, anon, postgres;
GRANT EXECUTE ON FUNCTION obtener_stock_bajo_dueno(BIGINT, INTEGER) TO authenticated, anon, postgres;
GRANT EXECUTE ON FUNCTION obtener_alertas_dueno(BIGINT, INTEGER) TO authenticated, anon, postgres;

