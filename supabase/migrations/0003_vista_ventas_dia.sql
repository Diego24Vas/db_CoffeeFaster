-- 1. Eliminamos la vista anterior para liberar la estructura
DROP VIEW IF EXISTS vista_ventas_dia;

-- 2. Creamos la vista con la nueva estructura
CREATE VIEW vista_ventas_dia AS
WITH items_por_pedido AS (
    SELECT
        pedido_id,
        SUM(cantidad) AS total_items
    FROM detalles_pedido
    GROUP BY pedido_id
)
SELECT
    p.creado_en::date AS fecha,
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
GROUP BY p.creado_en::date, c.id, c.nombre;

COMMENT ON VIEW vista_ventas_dia IS 'Consolida ventas diarias por cafetería: total en dinero, número de pedidos y promedios para dashboards, asegurando el cálculo correcto de totales.';
