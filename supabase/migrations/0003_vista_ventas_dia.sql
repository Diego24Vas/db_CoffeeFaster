CREATE OR REPLACE VIEW "vista_ventas_dia" AS
SELECT
    DATE(p."creado_en")                                        AS fecha,
    c."id"                                                     AS cafeteria_id,
    c."nombre"                                                 AS cafeteria_nombre,
    COALESCE(SUM(p."total"), 0)                                AS total_ventas,
    COUNT(p."id")                                              AS num_pedidos,
    CASE
        WHEN COUNT(p."id") > 0
        THEN ROUND(SUM(p."total") / COUNT(p."id"), 2)
        ELSE 0
    END                                                        AS promedio_venta,
    COALESCE(
        ROUND(
            SUM(dp."cantidad")::numeric / NULLIF(COUNT(p."id"), 0),
            2
        ),
        0
    )                                                          AS promedio_items_por_pedido
FROM "PEDIDOS" p
JOIN "CAFETERIAS" c       ON c."id" = p."cafeteria_id"
LEFT JOIN "DETALLES_PEDIDO" dp ON dp."pedido_id" = p."id"
WHERE p."estado" = 'entregado'
  AND p."pago_estado" = 'pagado'
GROUP BY DATE(p."creado_en"), c."id", c."nombre";

COMMENT ON VIEW "vista_ventas_dia" IS 'Consolida ventas diarias por cafetería: total en dinero, número de pedidos y promedios para dashboards.';
