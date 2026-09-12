-- =============================================================================
-- Migración: 0004_trigger_alerta_stock_bajo.sql
-- Trigger y Webhook nativo de Alerta de Stock Bajo (pg_net)
-- Tabla objetivo: productos
-- =============================================================================

-- 1. Habilitar la extensión de red asíncrona pg_net (si no está activa)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 2. Crear la función disparadora del Webhook
CREATE OR REPLACE FUNCTION notificar_stock_bajo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
    -- Umbral de alerta: valor fijo (ej. 10 unidades).
    -- Si prefieres usar el valor por producto definido en la tabla:
    -- v_umbral INTEGER := COALESCE(NULLIF(NEW.stock_minimo, 0), 10);
    v_umbral CONSTANT INTEGER := 10;
    v_payload JSONB;
BEGIN
    -- Condición Antispam:
    -- Solo se dispara cuando el stock anterior superaba el umbral 
    -- y el nuevo stock es igual o menor al umbral.
    IF OLD.stock IS NOT NULL 
       AND NEW.stock IS NOT NULL 
       AND OLD.stock > v_umbral 
       AND NEW.stock <= v_umbral THEN

        -- Construcción del payload JSON estructurado
        v_payload := jsonb_build_object(
            'evento', 'ALERTA_STOCK_BAJO',
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

        -- Envío HTTP POST asíncrono hacia el bot de Python
        PERFORM net.http_post(
            url := '[DEJA_UN_ESPACIO_PARA_LA_URL]',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'User-Agent', 'Supabase-pg_net-StockNotifier/1.0'
            ),
            body := v_payload,
            timeout_milliseconds := 5000
        );

    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notificar_stock_bajo() IS 
'Evalúa el cambio de inventario en productos y despacha un webhook asíncrono con pg_net al cruzar el umbral hacia abajo (antispam).';

-- 3. Crear el Trigger en la tabla productos
DROP TRIGGER IF EXISTS tr_alerta_stock_bajo ON productos;

CREATE TRIGGER tr_alerta_stock_bajo
    AFTER UPDATE ON productos
    FOR EACH ROW
    EXECUTE FUNCTION notificar_stock_bajo();

COMMENT ON TRIGGER tr_alerta_stock_bajo ON productos IS 
'Dispara la función notificar_stock_bajo() tras actualizar registros en la tabla productos.';
