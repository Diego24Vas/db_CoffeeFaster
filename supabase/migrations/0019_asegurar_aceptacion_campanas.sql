-- S3-T4: permisos, vigencia y aceptación de campañas. Requiere 0018.
BEGIN;

-- La identidad se obtiene únicamente del JWT; no depende de helpers externos.
CREATE OR REPLACE FUNCTION public.dueno_campana_id(p_cafeteria_id bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT u.id FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    JOIN public.cafeteria_usuarios cu ON cu.usuario_id = u.id
    WHERE u.auth_user_id = auth.uid() AND u.activo = true
      AND lower(r.nombre) IN ('dueño', 'dueno') AND cu.cafeteria_id = p_cafeteria_id
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.dueno_campana_id(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dueno_campana_id(bigint) TO authenticated;

ALTER TABLE public.campanas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.campanas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.campanas TO authenticated;
GRANT ALL ON public.campanas TO service_role;

DROP POLICY IF EXISTS campanas_insert_dueno ON public.campanas;
DROP POLICY IF EXISTS campanas_update_dueno ON public.campanas;
DROP POLICY IF EXISTS campanas_select_operador ON public.campanas;
CREATE POLICY campanas_select_operador ON public.campanas FOR SELECT TO authenticated
    USING (public.dueno_campana_id(cafeteria_id) IS NOT NULL);

-- Una aceptación conserva sus condiciones. Para otra versión se crea otra campaña.
CREATE OR REPLACE FUNCTION public.proteger_confirmacion_campanas()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') THEN
        RAISE EXCEPTION 'Utilice la RPC para confirmar condiciones' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.confirmada_por_dueno AND ROW(
            NEW.cafeteria_id, NEW.nombre, NEW.descripcion, NEW.tipo, NEW.version_condiciones,
            NEW.tasa_descuento, NEW.tasa_comision, NEW.vigencia_desde, NEW.vigencia_hasta,
            NEW.confirmada_por_dueno, NEW.fecha_confirmacion, NEW.usuario_confirma_id, NEW.version_confirmada
        ) IS DISTINCT FROM ROW(
            OLD.cafeteria_id, OLD.nombre, OLD.descripcion, OLD.tipo, OLD.version_condiciones,
            OLD.tasa_descuento, OLD.tasa_comision, OLD.vigencia_desde, OLD.vigencia_hasta,
            OLD.confirmada_por_dueno, OLD.fecha_confirmacion, OLD.usuario_confirma_id, OLD.version_confirmada
        ) THEN
            RAISE EXCEPTION 'La aceptación es inmutable; cree una nueva campaña para otras condiciones'
                USING ERRCODE = '22023';
        END IF;
        IF ROW(NEW.nombre, NEW.descripcion, NEW.tasa_descuento, NEW.tasa_comision, NEW.vigencia_desde, NEW.vigencia_hasta)
            IS DISTINCT FROM ROW(OLD.nombre, OLD.descripcion, OLD.tasa_descuento, OLD.tasa_comision, OLD.vigencia_desde, OLD.vigencia_hasta)
            AND trim(NEW.version_condiciones) = trim(OLD.version_condiciones) THEN
            RAISE EXCEPTION 'Cambiar condiciones requiere una nueva versión' USING ERRCODE = '22023';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.proteger_confirmacion_campanas() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_proteger_confirmacion_campanas ON public.campanas;
CREATE TRIGGER trg_proteger_confirmacion_campanas BEFORE INSERT OR UPDATE ON public.campanas
    FOR EACH ROW EXECUTE FUNCTION public.proteger_confirmacion_campanas();

-- La selección y los límites de vigencia usan el reloj de PostgreSQL y RLS.
CREATE OR REPLACE FUNCTION public.obtener_campana_vigente(p_cafeteria_id bigint)
RETURNS SETOF public.campanas LANGUAGE sql STABLE SET search_path = public AS $$
    SELECT * FROM public.campanas
    WHERE cafeteria_id = p_cafeteria_id AND tipo = 'carrito_completo'
      AND estado IN ('pendiente_aceptacion', 'activa')
      AND vigencia_desde <= current_timestamp AND vigencia_hasta > current_timestamp
    ORDER BY (confirmada_por_dueno AND version_confirmada = version_condiciones) ASC,
             creado_en DESC, id DESC
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.obtener_campana_vigente(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_campana_vigente(bigint) TO authenticated;

-- Retirar la firma anterior elimina también la vía anónima con p_usuario_id.
DROP FUNCTION IF EXISTS public.confirmar_condiciones_campana(bigint, bigint, bigint, text);
CREATE OR REPLACE FUNCTION public.confirmar_condiciones_campana(
    p_campana_id bigint, p_cafeteria_id bigint, p_version text
)
RETURNS public.campanas LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_usuario_id bigint;
    v_campana public.campanas;
BEGIN
    v_usuario_id := public.dueno_campana_id(p_cafeteria_id);
    IF auth.uid() IS NULL OR v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'Solo el dueño activo de la cafetería puede confirmar' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_campana FROM public.campanas
    WHERE id = p_campana_id AND cafeteria_id = p_cafeteria_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Campaña no encontrada' USING ERRCODE = 'P0002';
    END IF;
    IF trim(coalesce(p_version, '')) = '' OR trim(p_version) IS DISTINCT FROM trim(v_campana.version_condiciones) THEN
        RAISE EXCEPTION 'La versión cambió; revise las condiciones de nuevo' USING ERRCODE = '22023';
    END IF;
    IF v_campana.estado NOT IN ('pendiente_aceptacion', 'activa') OR
       v_campana.vigencia_desde > clock_timestamp() OR v_campana.vigencia_hasta <= clock_timestamp() THEN
        RAISE EXCEPTION 'La campaña no está vigente para aceptar condiciones' USING ERRCODE = '22023';
    END IF;
    IF v_campana.confirmada_por_dueno THEN
        IF v_campana.version_confirmada IS DISTINCT FROM v_campana.version_condiciones THEN
            RAISE EXCEPTION 'La aceptación no corresponde a la versión vigente' USING ERRCODE = '22023';
        END IF;
        RETURN v_campana;
    END IF;
    UPDATE public.campanas SET confirmada_por_dueno = true, fecha_confirmacion = clock_timestamp(),
        usuario_confirma_id = v_usuario_id, version_confirmada = trim(p_version), estado = 'activa',
        actualizado_en = clock_timestamp()
    WHERE id = p_campana_id RETURNING * INTO v_campana;
    RETURN v_campana;
END;
$$;
REVOKE ALL ON FUNCTION public.confirmar_condiciones_campana(bigint, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_condiciones_campana(bigint, bigint, text) TO authenticated;

-- 7. Soporte para Supabase Realtime si la publicación existe
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'campanas'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.campanas;
        END IF;
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
