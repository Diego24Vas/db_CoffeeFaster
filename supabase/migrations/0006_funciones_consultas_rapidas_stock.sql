-- ====================================================================
-- MIGRACIÓN 0006: Funciones de Accesos Rápidos para Consultas Frecuentes
-- Permite al bot de Telegram ejecutar consultas directas de:
-- 1. Consultar stock general
-- 2. Productos con stock bajo
-- 3. Productos agotados
-- ====================================================================

-- 1. Función para obtener stock general del dueño vinculado
CREATE OR REPLACE FUNCTION public.obtener_stock_general_dueno(p_chat_id bigint)
RETURNS TABLE(
    id bigint,
    nombre character varying,
    stock integer,
    stock_minimo integer,
    precio numeric,
    cafeteria_id bigint,
    cafeteria_nombre character varying
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

-- 2. Función para obtener productos con stock bajo (crítico pero con existencias > 0)
CREATE OR REPLACE FUNCTION public.obtener_stock_bajo_dueno(p_chat_id bigint, p_umbral integer DEFAULT 10)
RETURNS TABLE(
    id bigint,
    nombre character varying,
    stock integer,
    stock_minimo integer,
    cafeteria_id bigint,
    cafeteria_nombre character varying
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

-- 3. Función para obtener productos agotados (quiebre de stock <= 0)
CREATE OR REPLACE FUNCTION public.obtener_stock_agotado_dueno(p_chat_id bigint)
RETURNS TABLE(
    id bigint,
    nombre character varying,
    stock integer,
    stock_minimo integer,
    cafeteria_id bigint,
    cafeteria_nombre character varying
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
