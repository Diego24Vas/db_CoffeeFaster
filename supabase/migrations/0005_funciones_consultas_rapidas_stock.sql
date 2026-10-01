-- ====================================================================
-- MIGRACIÓN 0005: Funciones y Triggers para Bot de Telegram y Gestión de Stock
-- Incluye:
-- 1. Trigger de validación de rol dueño para Telegram
-- 2. Función de verificación de dueño vinculado
-- 3. Función de consulta de últimas alertas exclusivas por cafetería
-- 4. Funciones de acceso rápido: Stock general, bajo y agotado
-- ====================================================================

-- 1. Trigger de validación de rol 'dueño' para configuracion_telegram_dueno
CREATE OR REPLACE FUNCTION public.validar_rol_dueno_telegram()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
        INSERT INTO cafeteria_usuarios (usuario_id, cafeteria_id, cargo, gestiona_inventario, gestiona_productos)
        VALUES (NEW.usuario_id, NEW.cafeteria_id, 'Dueño / Administrador', true, true)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_validar_dueno_telegram ON configuracion_telegram_dueno;
CREATE TRIGGER tr_validar_dueno_telegram
    BEFORE INSERT OR UPDATE ON configuracion_telegram_dueno
    FOR EACH ROW
    EXECUTE FUNCTION validar_rol_dueno_telegram();

-- 2. Función para verificar si un chat_id pertenece a un Dueño activo
CREATE OR REPLACE FUNCTION public.verificar_dueno_telegram(p_chat_id BIGINT)
RETURNS TABLE(
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR,
    dueno_id BIGINT,
    dueno_nombre VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
$$;

-- 3. Función para obtener últimas alertas del dueño vinculado
CREATE OR REPLACE FUNCTION public.obtener_alertas_dueno(
    p_chat_id BIGINT,
    p_limite INTEGER DEFAULT 5
)
RETURNS TABLE(
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
    creado_en TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
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
    ORDER BY ultimas_alertas.creado_en DESC
    LIMIT p_limite;
END;
$$;

-- 4. Función para obtener stock general del dueño vinculado
CREATE OR REPLACE FUNCTION public.obtener_stock_general_dueno(p_chat_id BIGINT)
RETURNS TABLE(
    id BIGINT,
    nombre VARCHAR,
    stock INTEGER,
    stock_minimo INTEGER,
    precio NUMERIC,
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.id,
        p.nombre,
        p.stock,
        p.stock_minimo,
        p.precio,
        p.cafeteria_id,
        c.nombre AS cafeteria_nombre
    FROM productos p
    JOIN cafeterias c ON c.id = p.cafeteria_id
    JOIN configuracion_telegram_dueno ctd ON ctd.cafeteria_id = p.cafeteria_id
    WHERE ctd.telegram_chat_id = p_chat_id
      AND (p.activo = true OR p.activo IS NULL)
      AND p.eliminado_en IS NULL
    ORDER BY p.stock ASC, p.nombre ASC;
END;
$$;

-- 5. Función para obtener productos con stock bajo (crítico pero con existencias > 0)
CREATE OR REPLACE FUNCTION public.obtener_stock_bajo_dueno(
    p_chat_id BIGINT,
    p_umbral INTEGER DEFAULT 10
)
RETURNS TABLE(
    id BIGINT,
    nombre VARCHAR,
    stock INTEGER,
    stock_minimo INTEGER,
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
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
      AND p.stock > 0
      AND (p.stock <= p.stock_minimo OR p.stock <= p_umbral)
      AND (p.activo = true OR p.activo IS NULL)
      AND p.eliminado_en IS NULL
    ORDER BY p.stock ASC, p.nombre ASC;
END;
$$;

-- 6. Función para obtener productos agotados (quiebre de stock <= 0)
CREATE OR REPLACE FUNCTION public.obtener_stock_agotado_dueno(p_chat_id BIGINT)
RETURNS TABLE(
    id BIGINT,
    nombre VARCHAR,
    stock INTEGER,
    stock_minimo INTEGER,
    cafeteria_id BIGINT,
    cafeteria_nombre VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
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
      AND p.stock <= 0
      AND (p.activo = true OR p.activo IS NULL)
      AND p.eliminado_en IS NULL
    ORDER BY p.nombre ASC;
END;
$$;
