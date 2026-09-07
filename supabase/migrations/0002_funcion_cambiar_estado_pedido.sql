CREATE OR REPLACE FUNCTION cambiar_estado_pedido(
    p_pedido_id BIGINT,
    p_nuevo_estado VARCHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_estado_actual VARCHAR;
    v_creado_en TIMESTAMP;
BEGIN
    -- 1. Obtener datos actuales y bloquear la fila para evitar condiciones de carrera (concurrency)
    SELECT estado, creado_en INTO v_estado_actual, v_creado_en
    FROM pedidos
    WHERE id = p_pedido_id FOR UPDATE;

    -- 2. Validar que el pedido exista
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido con ID % no existe.', p_pedido_id;
    END IF;

    -- 3. Prevenir cambios ilógicos (ej. modificar un pedido que ya se entregó)
    IF v_estado_actual IN ('entregado', 'cancelado') THEN
        RAISE EXCEPTION 'Operación rechazada: El pedido ya está en estado final (%).', v_estado_actual;
    END IF;

    -- 4. Ejecutar el cambio de estado y registrar auditoría de tiempo
    IF p_nuevo_estado = 'preparando' THEN
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
