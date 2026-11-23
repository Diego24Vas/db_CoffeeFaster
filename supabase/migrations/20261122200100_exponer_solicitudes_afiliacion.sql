-- C05. Requiere V04 (0020), V05 (0021) y C04 (0023–0024).
BEGIN;

CREATE FUNCTION public.crear_solicitud_afiliacion(
    p_cafeteria_id bigint, p_campana_id bigint, p_plan_promocion text, p_enlace_publico text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_estudiante bigint := public.estudiante_afiliacion_id();
    v_solicitud public.solicitudes_afiliacion;
    v_creada boolean := false;
BEGIN
    IF v_estudiante IS NULL THEN
        RAISE EXCEPTION 'estudiante_requerido' USING ERRCODE = '42501';
    END IF;
    IF p_plan_promocion IS NULL OR p_plan_promocion !~ '[^[:space:]]' THEN
        RAISE EXCEPTION 'plan_promocion_requerido' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM public.campanas c JOIN public.cafeterias f ON f.id = c.cafeteria_id
    WHERE c.id = p_campana_id AND f.id = p_cafeteria_id FOR SHARE OF c, f;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'campana_no_disponible' USING ERRCODE = '55000';
    END IF;
    SELECT * INTO v_solicitud FROM public.solicitudes_afiliacion
    WHERE estudiante_id = v_estudiante AND campana_id = p_campana_id;
    IF NOT FOUND THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.listar_oportunidades_campana(p_cafeteria_id) c WHERE c.id = p_campana_id
        ) THEN
            RAISE EXCEPTION 'campana_no_disponible' USING ERRCODE = '55000';
        END IF;
        INSERT INTO public.solicitudes_afiliacion (estudiante_id, campana_id, plan_promocion, enlace_publico)
        VALUES (v_estudiante, p_campana_id, p_plan_promocion, p_enlace_publico)
        ON CONFLICT ON CONSTRAINT uq_afiliacion_estudiante_campana DO NOTHING
        RETURNING * INTO v_solicitud;
        v_creada := FOUND;
        IF NOT v_creada THEN
            SELECT * INTO STRICT v_solicitud FROM public.solicitudes_afiliacion
            WHERE estudiante_id = v_estudiante AND campana_id = p_campana_id;
        END IF;
    END IF;
    RETURN jsonb_build_object('creada', v_creada, 'solicitud', to_jsonb(v_solicitud));
END;
$$;

CREATE FUNCTION public.listar_solicitudes_afiliacion(p_cafeteria_id bigint, p_campana_id bigint)
RETURNS TABLE (id bigint, solicitante text, estado text, plan_promocion text, enlace_publico text,
               codigo text, codigo_activo boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF public.dueno_campana_id(p_cafeteria_id) IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.campanas c WHERE c.id = p_campana_id AND c.cafeteria_id = p_cafeteria_id
    ) THEN
        RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT s.id, concat_ws(' ', u.nombre, u.apellido), s.estado, s.plan_promocion,
           s.enlace_publico, s.codigo, s.codigo_activo
    FROM public.solicitudes_afiliacion s JOIN public.usuarios u ON u.id = s.estudiante_id
    WHERE s.campana_id = p_campana_id ORDER BY s.creado_en DESC, s.id DESC;
END;
$$;

CREATE FUNCTION public.consultar_mis_solicitudes_afiliacion()
RETURNS TABLE (id bigint, cafeteria_id bigint, campana_id bigint, estado text, codigo text, codigo_activo boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_estudiante bigint := public.estudiante_afiliacion_id();
BEGIN
    IF v_estudiante IS NULL THEN
        RAISE EXCEPTION 'estudiante_requerido' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT s.id, c.cafeteria_id, s.campana_id, s.estado, s.codigo, s.codigo_activo
    FROM public.solicitudes_afiliacion s JOIN public.campanas c ON c.id = s.campana_id
    WHERE s.estudiante_id = v_estudiante ORDER BY s.creado_en DESC, s.id DESC;
END;
$$;

CREATE FUNCTION public.resolver_solicitud_afiliacion_campana(
    p_cafeteria_id bigint, p_campana_id bigint, p_solicitud_id bigint, p_decision text, p_codigo text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF public.dueno_campana_id(p_cafeteria_id) IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.solicitudes_afiliacion s JOIN public.campanas c ON c.id = s.campana_id
        WHERE s.id = p_solicitud_id AND c.id = p_campana_id AND c.cafeteria_id = p_cafeteria_id
    ) THEN
        RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
    END IF;
    RETURN to_jsonb(public.resolver_solicitud_afiliacion(p_solicitud_id, p_decision, p_codigo));
END;
$$;

REVOKE ALL ON FUNCTION
    public.crear_solicitud_afiliacion(bigint, bigint, text, text),
    public.listar_solicitudes_afiliacion(bigint, bigint),
    public.consultar_mis_solicitudes_afiliacion(),
    public.resolver_solicitud_afiliacion_campana(bigint, bigint, bigint, text, text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
    public.crear_solicitud_afiliacion(bigint, bigint, text, text),
    public.listar_solicitudes_afiliacion(bigint, bigint),
    public.consultar_mis_solicitudes_afiliacion(),
    public.resolver_solicitud_afiliacion_campana(bigint, bigint, bigint, text, text)
    TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
