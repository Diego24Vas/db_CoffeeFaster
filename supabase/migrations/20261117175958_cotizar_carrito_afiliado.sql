-- V06 / CAM-288. Cotización de solo lectura; el consumo atómico corresponde a V07/V08.
BEGIN;

-- Se conserva tasa_descuento como tasa normal para los consumidores existentes.
-- NULL evita inventar condiciones para campañas históricas ya aceptadas.
ALTER TABLE public.campanas ADD COLUMN IF NOT EXISTS tasa_descuento_oferta numeric(5,2);
-- Mismos nombres que C03: ambos órdenes de instalación comparten restricciones.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.campanas'::regclass
        AND conname = 'campanas_tasa_oferta_rango') THEN
        ALTER TABLE public.campanas ADD CONSTRAINT campanas_tasa_oferta_rango
            CHECK (tasa_descuento_oferta IS NULL OR tasa_descuento_oferta BETWEEN 0 AND 100);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.campanas'::regclass
        AND conname = 'campanas_tasa_oferta_menor_igual') THEN
        ALTER TABLE public.campanas ADD CONSTRAINT campanas_tasa_oferta_menor_igual
            CHECK (tasa_descuento_oferta IS NULL OR tasa_descuento_oferta <= tasa_descuento);
    END IF;
END $$;
COMMENT ON COLUMN public.campanas.tasa_descuento_oferta IS
    'C01: descuento adicional sobre precio en oferta. NULL exige preparar una nueva campaña con ambas tasas antes del canje.';

-- Misma regla del pago existente: mayor promoción vigente, sin acumulación,
-- redondeo por unidad y mínimo de 1 CLP. Un único helper para pago y cotización.
CREATE OR REPLACE FUNCTION public.precio_promocional(
    p_producto_id bigint, p_cafeteria_id bigint, p_precio_base numeric
)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT CASE WHEN max(pr.descuento_porcentaje) IS NULL THEN p_precio_base
        ELSE greatest(1, round(p_precio_base * (100 - max(pr.descuento_porcentaje)) / 100)) END
    FROM public.promociones pr
    WHERE pr.cafeteria_id = p_cafeteria_id AND (pr.producto_id IS NULL OR pr.producto_id = p_producto_id)
      AND pr.activo AND (pr.inicio_en IS NULL OR pr.inicio_en <= statement_timestamp())
      AND (pr.fin_en IS NULL OR statement_timestamp() < pr.fin_en);
$$;
REVOKE ALL ON FUNCTION public.precio_promocional(bigint,bigint,numeric)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE SCHEMA afiliados_privado;
REVOKE ALL ON SCHEMA afiliados_privado FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA afiliados_privado TO authenticated;

CREATE FUNCTION afiliados_privado.cotizar_carrito(
    p_cafeteria_id bigint, p_items jsonb, p_codigo text
)
RETURNS TABLE (subtotal bigint, descuento_afiliado bigint, total bigint, comision bigint, motivo text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_comprador bigint;
    v_item jsonb;
    v_codigo text := upper(btrim(coalesce(p_codigo, '')));
    v_campana public.campanas;
    v_afiliacion public.solicitudes_afiliacion;
    v_normal numeric;
    v_oferta numeric;
    v_productos integer;
    v_encontrados integer;
BEGIN
    SELECT u.id INTO v_comprador FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() AND u.activo AND r.activo;
    IF v_comprador IS NULL THEN
        RAISE EXCEPTION 'Se requiere la sesión de un usuario activo' USING ERRCODE = '42501';
    END IF;
    IF p_cafeteria_id IS NULL OR p_cafeteria_id <= 0 THEN
        RAISE EXCEPTION 'cafeteria_invalida' USING ERRCODE = '22023';
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'items_invalidos' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'El carrito requiere entre 1 y 100 líneas' USING ERRCODE = '22023';
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item->'producto_id') IS DISTINCT FROM 'number'
           OR jsonb_typeof(v_item->'cantidad') IS DISTINCT FROM 'number'
           OR (v_item->>'producto_id') !~ '^[1-9][0-9]{0,18}$'
           OR (v_item->>'cantidad') !~ '^[1-9][0-9]{0,3}$' THEN
            RAISE EXCEPTION 'items_invalidos' USING ERRCODE = '22023';
        END IF;
        IF (v_item->>'producto_id')::numeric > 9223372036854775807
           OR (v_item->>'cantidad')::integer > 1000 THEN
            RAISE EXCEPTION 'items_fuera_de_limite' USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_items) AS i(producto_id bigint, cantidad integer)
        GROUP BY i.producto_id HAVING sum(i.cantidad) > 1000) THEN
        RAISE EXCEPTION 'cantidad_fuera_de_limite' USING ERRCODE = '22023';
    END IF;

    WITH items AS (
        SELECT i.producto_id, sum(i.cantidad) AS cantidad
        FROM jsonb_to_recordset(p_items) AS i(producto_id bigint, cantidad integer)
        GROUP BY i.producto_id
    ), precios AS MATERIALIZED (
        SELECT i.cantidad, p.id, round(p.precio) AS precio_base,
            round(public.precio_promocional(p.id, p.cafeteria_id, p.precio)) AS precio
        FROM items i LEFT JOIN public.productos p ON p.id = i.producto_id
          AND p.cafeteria_id = p_cafeteria_id AND p.activo AND p.eliminado_en IS NULL
          AND p.precio BETWEEN 1 AND 99999999.99
    )
    SELECT count(*), count(id),
        coalesce(sum(precio * cantidad) FILTER (WHERE precio >= precio_base), 0),
        coalesce(sum(precio * cantidad) FILTER (WHERE precio < precio_base), 0)
    INTO v_productos, v_encontrados, v_normal, v_oferta FROM precios;
    IF v_productos <> v_encontrados THEN
        RAISE EXCEPTION 'producto_no_disponible' USING ERRCODE = '22023';
    END IF;
    subtotal := v_normal + v_oferta;
    descuento_afiliado := 0;
    total := subtotal;
    comision := 0;
    motivo := 'sin_codigo';
    IF v_codigo <> '' THEN
        -- Los códigos pendientes/rechazados son NULL por V04. No revelar sus IDs.
        SELECT s.* INTO v_afiliacion FROM public.solicitudes_afiliacion s
        JOIN public.campanas c ON c.id = s.campana_id
        JOIN public.usuarios u ON u.id = s.estudiante_id AND u.activo
        JOIN public.roles r ON r.id = u.rol_id AND r.activo AND lower(r.nombre) = 'estudiante'
        WHERE s.codigo = v_codigo AND c.cafeteria_id = p_cafeteria_id;
        IF NOT FOUND OR v_afiliacion.estado <> 'aprobada' THEN
            motivo := 'codigo_invalido';
        ELSIF NOT v_afiliacion.codigo_activo THEN
            motivo := 'codigo_desactivado';
        ELSE
            SELECT c.* INTO v_campana FROM public.campanas c WHERE c.id = v_afiliacion.campana_id;
            motivo := CASE
                WHEN v_campana.estado = 'pausada' THEN 'campana_pausada'
                WHEN v_campana.estado = 'finalizada' OR v_campana.vigencia_hasta <= statement_timestamp() THEN 'campana_finalizada'
                WHEN v_campana.vigencia_desde > statement_timestamp() THEN 'campana_no_iniciada'
                WHEN v_campana.estado NOT IN ('activa', 'aceptada') THEN 'campana_no_activa'
                WHEN NOT v_campana.confirmada_por_dueno
                    OR v_campana.version_confirmada IS DISTINCT FROM v_campana.version_condiciones THEN 'campana_no_aceptada'
                WHEN v_campana.tasa_descuento_oferta IS NULL THEN 'condiciones_incompletas'
                WHEN EXISTS (
                    SELECT 1 FROM public.movimientos_comision m
                    JOIN public.pedidos p ON p.id = m.pedido_id
                    WHERE p.usuario_id = v_comprador AND m.tipo = 'comision' AND m.estado <> 'revertida'
                ) THEN 'beneficio_usado'
                ELSE NULL END;
            IF motivo IS NULL THEN
                descuento_afiliado := round(v_normal * v_campana.tasa_descuento / 100)
                    + round(v_oferta * v_campana.tasa_descuento_oferta / 100);
                total := subtotal - descuento_afiliado;
                IF v_comprador <> v_afiliacion.estudiante_id THEN
                    comision := round(total * v_campana.tasa_comision / 100);
                END IF;
            END IF;
        END IF;
    END IF;
    RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION afiliados_privado.cotizar_carrito(bigint,jsonb,text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION afiliados_privado.cotizar_carrito(bigint,jsonb,text) TO authenticated;

-- Fachada pública sin privilegios elevados; la implementación privada valida el JWT.
CREATE FUNCTION public.cotizar_carrito_afiliado(p_cafeteria_id bigint, p_items jsonb, p_codigo text DEFAULT NULL)
RETURNS TABLE (subtotal bigint, descuento_afiliado bigint, total bigint, comision bigint, motivo text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
    SELECT * FROM afiliados_privado.cotizar_carrito(p_cafeteria_id, p_items, p_codigo);
$$;
REVOKE ALL ON FUNCTION public.cotizar_carrito_afiliado(bigint,jsonb,text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cotizar_carrito_afiliado(bigint,jsonb,text) TO authenticated;
COMMENT ON FUNCTION public.cotizar_carrito_afiliado(bigint,jsonb,text) IS
    'V06: importes CLP y motivo de inelegibilidad, sin cobrar ni consumir beneficio. V07/V08 deben serializar y revalidar al pagar.';

NOTIFY pgrst, 'reload schema';
COMMIT;
