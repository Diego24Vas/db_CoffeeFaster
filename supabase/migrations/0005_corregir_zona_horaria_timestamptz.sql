-- ====================================================================
-- MIGRACIÓN 0005: Corregir tipo de datos temporal a TIMESTAMPTZ y Realtime
-- Garantiza que las marcas de tiempo almacenen y transmitan la zona
-- horaria UTC correcta a los clientes (ej. PostgREST / app-desktop),
-- evitando el desfase de 3 horas (18:00 UTC vs 15:00 CLT), y habilita
-- la replicación en tiempo real completa para pedidos e inventario.
-- ====================================================================

-- 1. Eliminar temporalmente la vista que depende de pedidos.creado_en
DROP VIEW IF EXISTS vista_ventas_dia;

-- 2. Tabla: pedidos
ALTER TABLE pedidos 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP,
    ALTER COLUMN inicio_preparacion_en TYPE TIMESTAMPTZ USING (inicio_preparacion_en AT TIME ZONE 'UTC'),
    ALTER COLUMN listo_en TYPE TIMESTAMPTZ USING (listo_en AT TIME ZONE 'UTC'),
    ALTER COLUMN entregado_en TYPE TIMESTAMPTZ USING (entregado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN cancelado_en TYPE TIMESTAMPTZ USING (cancelado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN qr_expira_en TYPE TIMESTAMPTZ USING (qr_expira_en AT TIME ZONE 'UTC');

-- 3. Tabla: alertas_stock
ALTER TABLE alertas_stock 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP;

-- 4. Tabla: movimientos_inventario
ALTER TABLE movimientos_inventario 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP;

-- 5. Tabla: productos
ALTER TABLE productos 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP,
    ALTER COLUMN actualizado_en TYPE TIMESTAMPTZ USING (actualizado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN actualizado_en SET DEFAULT CURRENT_TIMESTAMP,
    ALTER COLUMN eliminado_en TYPE TIMESTAMPTZ USING (eliminado_en AT TIME ZONE 'UTC');

-- 6. Tabla: cafeteria_usuarios
ALTER TABLE cafeteria_usuarios 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP;

-- 7. Tabla: pagos
ALTER TABLE pagos 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP;

-- 8. Tabla: logs_validacion_qr
ALTER TABLE logs_validacion_qr 
    ALTER COLUMN creado_en TYPE TIMESTAMPTZ USING (creado_en AT TIME ZONE 'UTC'),
    ALTER COLUMN creado_en SET DEFAULT CURRENT_TIMESTAMP;

-- 9. Habilitar REPLICA IDENTITY FULL y publicación en supabase_realtime para pedidos e inventario
ALTER TABLE public.pedidos REPLICA IDENTITY FULL;
ALTER TABLE public.detalles_pedido REPLICA IDENTITY FULL;
ALTER TABLE public.movimientos_inventario REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'pedidos'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pedidos;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'detalles_pedido'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.detalles_pedido;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'movimientos_inventario'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.movimientos_inventario;
  END IF;
END $$;

-- 10. Actualizar función cambiar_estado_pedido con variable TIMESTAMPTZ
CREATE OR REPLACE FUNCTION cambiar_estado_pedido(
    p_pedido_id BIGINT,
    p_nuevo_estado VARCHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_estado_actual VARCHAR;
    v_creado_en TIMESTAMPTZ;
BEGIN
    SELECT estado, creado_en INTO v_estado_actual, v_creado_en
    FROM pedidos
    WHERE id = p_pedido_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido con ID % no existe.', p_pedido_id;
    END IF;

    IF v_estado_actual IN ('entregado', 'cancelado') THEN
        RAISE EXCEPTION 'Operación rechazada: El pedido ya está en estado final (%).', v_estado_actual;
    END IF;

    IF p_nuevo_estado = 'preparando' OR p_nuevo_estado = 'en_preparacion' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            inicio_preparacion_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'listo' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            listo_en = CURRENT_TIMESTAMP,
            tiempo_real_min = ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_creado_en)) / 60)::INTEGER
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'entregado' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            entregado_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'cancelado' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            cancelado_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSE
        RAISE EXCEPTION 'Estado no reconocido: %', p_nuevo_estado;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- 11. Recrear vista vista_ventas_dia con conversión a zona horaria local de Chile
CREATE VIEW vista_ventas_dia AS
WITH items_por_pedido AS (
    SELECT
        pedido_id,
        SUM(cantidad) AS total_items
    FROM detalles_pedido
    GROUP BY pedido_id
)
SELECT
    (p.creado_en AT TIME ZONE 'America/Santiago')::date AS fecha,
    c.id AS cafeteria_id,
    c.nombre AS cafeteria_nombre,

    COALESCE(SUM(p.total), 0) AS total_ventas,
    COUNT(p.id) AS num_pedidos,

    CASE
        WHEN COUNT(p.id) > 0
        THEN ROUND(SUM(p.total) / COUNT(p.id), 2)
        ELSE 0
    END AS promedio_venta,

    COALESCE(
        ROUND(
            SUM(i.total_items)::numeric / NULLIF(COUNT(p.id), 0), 2
        ), 0
    ) AS promedio_items_por_pedido

FROM pedidos p
JOIN cafeterias c ON c.id = p.cafeteria_id
LEFT JOIN items_por_pedido i ON i.pedido_id = p.id
WHERE p.estado = 'entregado'
  AND p.pago_estado = 'pagado'
GROUP BY (p.creado_en AT TIME ZONE 'America/Santiago')::date, c.id, c.nombre;
