-- ====================================================================
-- PRUEBA REPRODUCIBLE: V03 · Esquema de campañas y condiciones
-- Valida:
-- 1. Inserción exitosa de campaña de carrito completo con tasas y vigencia válidas.
-- 2. Rechazo ante tasas fuera de rango (CHECK tasa_descuento / tasa_comision).
-- 3. Rechazo ante vigencias inválidas (CHECK ck_campanas_vigencia).
-- 4. Confirmación de condiciones por el dueño (confirmar_condiciones_campana).
-- 5. Idempotencia: doble llamada no duplica aceptación.
-- 6. Consulta del estado final persistido.
-- ====================================================================

DO $$
DECLARE
    v_cafeteria_id bigint;
    v_usuario_id bigint;
    v_campana_id bigint;
    v_campana_res public.campanas;
    v_error_tasa boolean := false;
    v_error_vigencia boolean := false;
BEGIN
    RAISE NOTICE '>>> INICIANDO PRUEBA REPRODUCIBLE V03 · ESQUEMA DE CAMPAÑAS <<<';

    -- 1. Obtener o crear cafetería y usuario para la prueba
    SELECT id INTO v_cafeteria_id FROM public.cafeterias LIMIT 1;
    IF v_cafeteria_id IS NULL THEN
        INSERT INTO public.cafeterias (nombre, activa)
        VALUES ('Cafetería Central Test V03', true)
        RETURNING id INTO v_cafeteria_id;
    END IF;

    SELECT id INTO v_usuario_id FROM public.usuarios LIMIT 1;
    IF v_usuario_id IS NULL THEN
        INSERT INTO public.usuarios (nombre)
        VALUES ('Dueño Test V03')
        RETURNING id INTO v_usuario_id;
    END IF;

    RAISE NOTICE 'Cafeteria ID: %, Usuario Dueño ID: %', v_cafeteria_id, v_usuario_id;

    -- 2. Caso 1: Guardar una campaña de carrito completo válida
    INSERT INTO public.campanas (
        cafeteria_id,
        nombre,
        descripcion,
        tipo,
        estado,
        version_condiciones,
        tasa_descuento,
        tasa_comision,
        vigencia_desde,
        vigencia_hasta
    ) VALUES (
        v_cafeteria_id,
        'Campaña Verano Carrito Completo 2026',
        'Descuento del 15% en todo el pedido con comisión acordada del 5%',
        'carrito_completo',
        'pendiente_aceptacion',
        'v1.0',
        15.00,
        5.00,
        clock_timestamp(),
        clock_timestamp() + interval '30 days'
    )
    RETURNING id INTO v_campana_id;

    RAISE NOTICE '[OK] Caso 1: Campaña creada exitosamente con ID %', v_campana_id;

    -- 3. Caso 2: Verificar restricción CHECK de tasas (> 100)
    BEGIN
        INSERT INTO public.campanas (
            cafeteria_id, nombre, tipo, tasa_descuento, tasa_comision,
            vigencia_desde, vigencia_hasta
        ) VALUES (
            v_cafeteria_id, 'Campaña Tasa Inválida', 'carrito_completo', 150.00, 5.00,
            clock_timestamp(), clock_timestamp() + interval '1 day'
        );
    EXCEPTION WHEN check_violation THEN
        v_error_tasa := true;
        RAISE NOTICE '[OK] Caso 2: CHECK de tasa_descuento rechazó correctamente tasa mayor a 100';
    END;

    IF NOT v_error_tasa THEN
        RAISE EXCEPTION 'FALLO: Se permitió tasa de descuento > 100';
    END IF;

    -- 4. Caso 3: Verificar restricción CHECK de vigencia (vigencia_hasta <= vigencia_desde)
    BEGIN
        INSERT INTO public.campanas (
            cafeteria_id, nombre, tipo, tasa_descuento, tasa_comision,
            vigencia_desde, vigencia_hasta
        ) VALUES (
            v_cafeteria_id, 'Campaña Vigencia Inválida', 'carrito_completo', 10.00, 5.00,
            clock_timestamp(), clock_timestamp() - interval '1 day'
        );
    EXCEPTION WHEN check_violation THEN
        v_error_vigencia := true;
        RAISE NOTICE '[OK] Caso 3: CHECK ck_campanas_vigencia rechazó correctamente vigencia invertida';
    END;

    IF NOT v_error_vigencia THEN
        RAISE EXCEPTION 'FALLO: Se permitió vigencia con fin anterior al inicio';
    END IF;

    -- 5. Caso 4: Dueño confirma condiciones por primera vez
    v_campana_res := public.confirmar_condiciones_campana(
        v_campana_id,
        v_cafeteria_id,
        v_usuario_id,
        'v1.0'
    );

    IF v_campana_res.confirmada_por_dueno IS NOT TRUE THEN
        RAISE EXCEPTION 'FALLO: La campaña no quedó confirmada';
    END IF;
    RAISE NOTICE '[OK] Caso 4: Campaña confirmada por dueño. Estado: %, Confirmada: %',
        v_campana_res.estado, v_campana_res.confirmada_por_dueno;

    -- 6. Caso 5: Doble confirmación (idempotencia ante doble clic)
    v_campana_res := public.confirmar_condiciones_campana(
        v_campana_id,
        v_cafeteria_id,
        v_usuario_id,
        'v1.0'
    );

    IF v_campana_res.confirmada_por_dueno IS NOT TRUE THEN
        RAISE EXCEPTION 'FALLO: La segunda confirmación alteró el estado';
    END IF;
    RAISE NOTICE '[OK] Caso 5: Segunda confirmación manejada de forma idempotente sin errores';

    RAISE NOTICE '>>> TODAS LAS COMPROBACIONES DE V03 FINALIZARON CON ÉXITO <<<';
END $$;

-- 7. Consulta final para observar el estado persistido
SELECT
    id,
    cafeteria_id,
    nombre,
    tipo,
    estado,
    version_condiciones,
    tasa_descuento || '%' AS tasa_descuento,
    tasa_comision || '%' AS tasa_comision,
    vigencia_desde,
    vigencia_hasta,
    confirmada_por_dueno,
    version_confirmada,
    fecha_confirmacion,
    usuario_confirma_id
FROM public.campanas
ORDER BY id DESC
LIMIT 1;
