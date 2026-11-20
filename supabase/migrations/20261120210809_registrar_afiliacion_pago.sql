-- V08 / CAM-176. C07 conecta esta sobrecarga al gateway. La firma legacy sigue intacta.
BEGIN;
ALTER TABLE public.pedidos ADD COLUMN IF NOT EXISTS stock_descontado boolean NOT NULL DEFAULT false;

CREATE TABLE afiliados_privado.intentos_pago (
    usuario_id bigint NOT NULL REFERENCES public.usuarios(id),
    clave text NOT NULL CHECK (length(clave) BETWEEN 1 AND 128),
    solicitud jsonb NOT NULL,
    resultado jsonb NOT NULL,
    PRIMARY KEY (usuario_id, clave)
);
ALTER TABLE afiliados_privado.intentos_pago ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON afiliados_privado.intentos_pago FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION afiliados_privado.procesar_pago(
    p_cafeteria_id bigint, p_items jsonb, p_franja_retiro text,
    p_codigo text, p_total_aceptado bigint, p_clave_idempotencia text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_usuario bigint;
    v_wallet public.wallets;
    v_solicitud jsonb;
    v_intento afiliados_privado.intentos_pago;
    v_resultado jsonb;
    v_codigo text := upper(btrim(coalesce(p_codigo, '')));
    v_afiliacion public.solicitudes_afiliacion;
    v_campana public.campanas;
    v_cotizacion record;
    v_detalles jsonb;
    v_producto record;
    v_stock integer;
    v_pedido public.pedidos;
    v_metodo bigint;
    v_qr text;
    v_retiro text;
    v_motivo text;
BEGIN
    SELECT u.id INTO v_usuario FROM public.usuarios u JOIN public.roles r ON r.id=u.rol_id
    WHERE u.auth_user_id=auth.uid() AND u.activo AND r.activo;
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'sin_sesion' USING ERRCODE='42501';
    END IF;
    IF p_clave_idempotencia IS NULL OR length(p_clave_idempotencia) NOT BETWEEN 1 AND 128
        OR btrim(p_clave_idempotencia)=''
        OR p_total_aceptado IS NULL OR p_total_aceptado < 0
        OR p_franja_retiro IS NULL OR btrim(p_franja_retiro)='' THEN
        RAISE EXCEPTION 'confirmacion_invalida' USING ERRCODE='22023';
    END IF;
    v_solicitud := jsonb_build_object('cafeteria',p_cafeteria_id,'items',p_items,
        'franja',p_franja_retiro,'codigo',v_codigo,'total',p_total_aceptado);
    -- Serializa la misma clave antes de consultar el resultado, incluso si cambió el catálogo.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
        'V08:'||v_usuario::text||':'||p_clave_idempotencia,0));
    SELECT * INTO v_intento FROM afiliados_privado.intentos_pago
    WHERE usuario_id=v_usuario AND clave=p_clave_idempotencia;
    IF FOUND THEN
        IF v_intento.solicitud IS DISTINCT FROM v_solicitud THEN
            RETURN jsonb_build_object('ok',false,'motivo','clave_reintento_en_conflicto','cobrado',false);
        END IF;
        RETURN v_intento.resultado;
    END IF;

    -- V06 valida identidad, estructura, cantidades y pertenencia de productos antes de bloquear.
    PERFORM * FROM afiliados_privado.cotizar_carrito(p_cafeteria_id,p_items,NULL);
    <<compra>>
    BEGIN
        -- Orden compatible con el pago con stock: productos por ID -> Wallet -> V07.
        FOR v_producto IN
            SELECT p.id,p.stock,sum(i.cantidad) AS cantidad
            FROM jsonb_to_recordset(p_items) AS i(producto_id bigint,cantidad integer)
            JOIN public.productos p ON p.id=i.producto_id
            GROUP BY p.id ORDER BY p.id
        LOOP
            SELECT stock INTO v_stock FROM public.productos WHERE id=v_producto.id FOR UPDATE;
            IF v_stock < v_producto.cantidad OR v_stock IS NULL THEN
                v_resultado := jsonb_build_object('ok',false,'motivo','stock_insuficiente','cobrado',false);
                EXIT compra;
            END IF;
        END LOOP;
        SELECT * INTO v_wallet FROM public.wallets WHERE usuario_id=v_usuario FOR UPDATE;
        IF NOT FOUND THEN
            v_resultado := jsonb_build_object('ok',false,'motivo','sin_wallet','cobrado',false);
            EXIT compra;
        END IF;
        PERFORM afiliados_privado.bloquear_comprador(v_usuario,p_cafeteria_id);

        -- Mismo orden que V05: afiliación antes de campaña. Bloquea desactivación y pausa.
        SELECT s.* INTO v_afiliacion FROM public.solicitudes_afiliacion s
        JOIN public.campanas c ON c.id=s.campana_id
        WHERE s.codigo=v_codigo AND c.cafeteria_id=p_cafeteria_id FOR SHARE OF s;
        IF FOUND THEN
            SELECT * INTO v_campana FROM public.campanas WHERE id=v_afiliacion.campana_id FOR SHARE;
            -- statement_timestamp de V06 puede ser anterior a una espera por bloqueos.
            IF v_campana.vigencia_hasta <= clock_timestamp() THEN v_motivo := 'campana_finalizada';
            ELSIF v_campana.vigencia_desde > clock_timestamp() THEN v_motivo := 'campana_no_iniciada';
            END IF;
        END IF;
        -- Cotización y precios unitarios comparten la misma instantánea SQL.
        SELECT q.*, (
            SELECT jsonb_agg(jsonb_build_object('producto_id',p.id,'cantidad',i.cantidad,
                'precio_unitario',round(public.precio_promocional(p.id,p.cafeteria_id,p.precio)),
                'subtotal',round(public.precio_promocional(p.id,p.cafeteria_id,p.precio))*i.cantidad) ORDER BY p.id)
            FROM (SELECT producto_id,sum(cantidad) AS cantidad
                FROM jsonb_to_recordset(p_items) AS x(producto_id bigint,cantidad integer) GROUP BY producto_id) i
            JOIN public.productos p ON p.id=i.producto_id
        ) AS detalles INTO v_cotizacion
        FROM afiliados_privado.cotizar_carrito(p_cafeteria_id,p_items,
            CASE WHEN v_motivo IS NULL THEN v_codigo ELSE NULL END) q;
        v_detalles := v_cotizacion.detalles;
        v_motivo := coalesce(v_motivo,v_cotizacion.motivo);
        IF v_cotizacion.total IS DISTINCT FROM p_total_aceptado THEN
            v_resultado := jsonb_build_object('ok',false,'error','precio_actualizado',
                'motivo',coalesce(v_motivo,'precio_actualizado'),'total_aceptado',p_total_aceptado,
                'total_actualizado',v_cotizacion.total,'descuento_afiliado',v_cotizacion.descuento_afiliado,'cobrado',false);
            EXIT compra;
        END IF;
        -- El cliente legacy todavía envía precio_esperado por línea.
        IF EXISTS (SELECT FROM jsonb_array_elements(p_items) i JOIN jsonb_array_elements(v_detalles) d
            ON (i->>'producto_id')::bigint=(d->>'producto_id')::bigint
            WHERE i ? 'precio_esperado' AND (i->>'precio_esperado')::numeric IS DISTINCT FROM (d->>'precio_unitario')::numeric) THEN
            v_resultado := jsonb_build_object('ok',false,'motivo','precio_actualizado',
                'total_actualizado',v_cotizacion.total,'cobrado',false);
            EXIT compra;
        END IF;
        IF v_wallet.saldo_actual IS NULL OR v_wallet.saldo_actual < v_cotizacion.total THEN
            v_resultado := jsonb_build_object('ok',false,'motivo','saldo_insuficiente','cobrado',false);
            EXIT compra;
        END IF;

        -- Ninguna escritura de negocio ocurre antes de la reconfirmación y los rechazos.
        UPDATE public.productos p SET stock=p.stock-(d->>'cantidad')::integer,actualizado_en=clock_timestamp()
        FROM jsonb_array_elements(v_detalles) d WHERE p.id=(d->>'producto_id')::bigint;
        UPDATE public.wallets SET saldo_actual=saldo_actual-v_cotizacion.total,actualizado_en=clock_timestamp()
        WHERE id=v_wallet.id RETURNING * INTO v_wallet;
        v_qr := public.generar_token_retiro('CF-',20);
        v_retiro := public.generar_token_retiro('',8);
        INSERT INTO public.pedidos(usuario_id,cafeteria_id,total,estado,pago_estado,metodo_pago,
            franja_retiro,qr_token,codigo_retiro_diario,qr_usado,stock_descontado)
        VALUES(v_usuario,p_cafeteria_id,v_cotizacion.total,'pendiente','pagado','wallet',
            p_franja_retiro,v_qr,v_retiro,false,true) RETURNING * INTO v_pedido;
        INSERT INTO public.detalles_pedido(pedido_id,producto_id,cantidad,precio_unitario,subtotal)
        SELECT v_pedido.id,d.producto_id,d.cantidad,d.precio_unitario,d.subtotal
        FROM jsonb_to_recordset(v_detalles) AS d(producto_id bigint,cantidad integer,precio_unitario numeric,subtotal numeric);
        SELECT id INTO STRICT v_metodo FROM public.metodos_pago WHERE codigo='WALLET';
        INSERT INTO public.pagos(pedido_id,metodo_pago_id,monto,estado,es_simulado,referencia_transaccion)
        VALUES(v_pedido.id,v_metodo,v_cotizacion.total,'aprobado',false,'wallet-pedido-'||v_pedido.id::text);
        INSERT INTO public.movimientos_wallet(wallet_id,pedido_id,tipo,monto,descripcion)
        VALUES(v_wallet.id,v_pedido.id,'compra',-v_cotizacion.total,'Compra cafeteria #'||p_cafeteria_id::text);
        IF v_motivo IS NULL THEN
            INSERT INTO public.movimientos_comision(afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp)
            VALUES(v_afiliacion.id,v_pedido.id,'comision',v_cotizacion.total,v_campana.tasa_comision,v_cotizacion.comision);
        END IF;
        v_resultado := jsonb_build_object('ok',true,'pedido_id',v_pedido.id,'codigo_pedido',v_pedido.codigo_pedido,
            'total',v_cotizacion.total,'total_pagado',v_cotizacion.total,'subtotal',v_cotizacion.subtotal,
            'descuento_afiliado',v_cotizacion.descuento_afiliado,'comision',v_cotizacion.comision,
            'saldo_restante',v_wallet.saldo_actual,'estado','pendiente','pago_estado','pagado',
            'franja_retiro',p_franja_retiro,'qr_token',v_qr,'codigo_retiro_diario',v_retiro,'codigo_retiro',v_retiro);
    END compra;
    INSERT INTO afiliados_privado.intentos_pago(usuario_id,clave,solicitud,resultado)
    VALUES(v_usuario,p_clave_idempotencia,v_solicitud,v_resultado);
    RETURN v_resultado;
END;
$$;
REVOKE ALL ON FUNCTION afiliados_privado.procesar_pago(bigint,jsonb,text,text,bigint,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION afiliados_privado.procesar_pago(bigint,jsonb,text,text,bigint,text) TO authenticated;
CREATE FUNCTION public.procesar_pago(
    p_cafeteria_id bigint, p_items jsonb, p_franja_retiro text,
    p_codigo text, p_total_aceptado bigint, p_clave_idempotencia text
)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
    SELECT afiliados_privado.procesar_pago(p_cafeteria_id,p_items,p_franja_retiro,p_codigo,p_total_aceptado,p_clave_idempotencia);
$$;
REVOKE ALL ON FUNCTION public.procesar_pago(bigint,jsonb,text,text,bigint,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.procesar_pago(bigint,jsonb,text,text,bigint,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
