-- V05 / CAM-172. Requiere V04 (0020). No modifica importes ni resoluciones previas.
BEGIN;

CREATE OR REPLACE FUNCTION public.dueno_campana_id(p_cafeteria_id bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT u.id FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    JOIN public.cafeteria_usuarios cu ON cu.usuario_id = u.id
    WHERE u.auth_user_id = auth.uid() AND u.activo AND r.activo
      AND lower(r.nombre) IN ('dueño', 'dueno') AND cu.cafeteria_id = p_cafeteria_id
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.dueno_campana_id(bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dueno_campana_id(bigint) TO authenticated;

CREATE FUNCTION public.resolver_solicitud_afiliacion(
    p_solicitud_id bigint, p_decision text, p_codigo text DEFAULT NULL
)
RETURNS public.solicitudes_afiliacion
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_solicitud public.solicitudes_afiliacion;
    v_dueno bigint;
    v_codigo text := upper(btrim(p_codigo));
    v_intento integer;
    v_restriccion text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Se requiere la sesión del dueño' USING ERRCODE = '42501';
    END IF;
    -- No bloquear filas ajenas ni revelar si un ID fuera del alcance existe.
    SELECT s.* INTO v_solicitud FROM public.solicitudes_afiliacion s
    JOIN public.campanas c ON c.id = s.campana_id
    WHERE s.id = p_solicitud_id AND public.dueno_campana_id(c.cafeteria_id) IS NOT NULL
    FOR UPDATE OF s;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Solicitud no disponible para este dueño' USING ERRCODE = '42501';
    END IF;
    SELECT public.dueno_campana_id(c.cafeteria_id) INTO v_dueno
    FROM public.campanas c WHERE c.id = v_solicitud.campana_id;
    IF v_dueno IS NULL THEN
        RAISE EXCEPTION 'El dueño ya no tiene acceso' USING ERRCODE = '42501';
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('aprobar', 'rechazar', 'desactivar')
       OR (p_decision <> 'aprobar' AND p_codigo IS NOT NULL) THEN
        RAISE EXCEPTION 'Decisión inválida o código no permitido' USING ERRCODE = '22023';
    END IF;
    IF p_codigo IS NOT NULL AND (length(v_codigo) NOT BETWEEN 1 AND 64 OR v_codigo ~ '[[:space:]]') THEN
        RAISE EXCEPTION 'Código inválido: máximo 64 caracteres, sin espacios' USING ERRCODE = '22023';
    END IF;

    IF p_decision = 'desactivar' THEN
        IF v_solicitud.estado <> 'aprobada' THEN
            RAISE EXCEPTION 'Solo se desactiva una afiliación aprobada' USING ERRCODE = '55000';
        END IF;
        IF NOT v_solicitud.codigo_activo THEN RETURN v_solicitud; END IF;
        UPDATE public.solicitudes_afiliacion SET codigo_activo = false
        WHERE id = v_solicitud.id RETURNING * INTO v_solicitud;
        RETURN v_solicitud;
    END IF;
    IF v_solicitud.estado <> 'pendiente' THEN
        IF (p_decision = 'rechazar' AND v_solicitud.estado = 'rechazada') OR
           (p_decision = 'aprobar' AND v_solicitud.estado = 'aprobada'
            AND (p_codigo IS NULL OR v_codigo = v_solicitud.codigo)) THEN
            RETURN v_solicitud;
        END IF;
        RAISE EXCEPTION 'La solicitud ya tiene otra resolución o código' USING ERRCODE = '55000';
    END IF;
    IF p_decision = 'rechazar' THEN
        UPDATE public.solicitudes_afiliacion SET estado = 'rechazada',
            resuelta_por = v_dueno, resuelta_en = clock_timestamp()
        WHERE id = v_solicitud.id RETURNING * INTO v_solicitud;
        RETURN v_solicitud;
    END IF;

    -- Una campaña futura puede aprobar afiliados; el canje se valida en V06/V08.
    PERFORM 1 FROM public.campanas c WHERE c.id = v_solicitud.campana_id
      AND c.estado IN ('activa', 'aceptada', 'pendiente_aceptacion')
      AND c.vigencia_hasta > clock_timestamp() FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La campaña no admite nuevas aprobaciones' USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.usuarios u JOIN public.roles r ON r.id = u.rol_id
        WHERE u.id = v_solicitud.estudiante_id AND u.activo AND r.activo AND lower(r.nombre) = 'estudiante') THEN
        RAISE EXCEPTION 'El solicitante debe ser un estudiante activo' USING ERRCODE = '55000';
    END IF;
    FOR v_intento IN 1..5 LOOP
        IF p_codigo IS NULL THEN
            v_codigo := 'CF-' || upper(replace(gen_random_uuid()::text, '-', ''));
        END IF;
        BEGIN
            UPDATE public.solicitudes_afiliacion SET estado = 'aprobada', codigo = v_codigo,
                codigo_activo = true, resuelta_por = v_dueno, resuelta_en = clock_timestamp()
            WHERE id = v_solicitud.id RETURNING * INTO v_solicitud;
            RETURN v_solicitud;
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_restriccion = CONSTRAINT_NAME;
            IF v_restriccion <> 'uq_afiliacion_codigo' THEN RAISE; END IF;
            IF p_codigo IS NOT NULL THEN
                RAISE EXCEPTION 'codigo_en_uso' USING ERRCODE = '23505', CONSTRAINT = 'uq_afiliacion_codigo';
            END IF;
        END;
    END LOOP;
    RAISE EXCEPTION 'No se pudo generar un código único; reintente' USING ERRCODE = '54000';
END;
$$;
REVOKE ALL ON FUNCTION public.resolver_solicitud_afiliacion(bigint, text, text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_afiliacion(bigint, text, text) TO authenticated;

-- C05 puede crear pendientes desde el servidor; las decisiones exigen la RPC.
REVOKE UPDATE ON public.solicitudes_afiliacion FROM service_role;
CREATE FUNCTION public.proteger_resolucion_afiliacion()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF current_user IN ('anon', 'authenticated', 'service_role')
       AND (TG_OP = 'UPDATE' OR NEW.estado <> 'pendiente') THEN
        RAISE EXCEPTION 'Utilice la RPC con la sesión del dueño para resolver afiliaciones'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.proteger_resolucion_afiliacion() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER proteger_resolucion_afiliacion BEFORE INSERT OR UPDATE ON public.solicitudes_afiliacion
    FOR EACH ROW EXECUTE FUNCTION public.proteger_resolucion_afiliacion();

-- FOR SHARE se mantiene hasta COMMIT y entra en conflicto con la desactivación.
-- No se aplica a cambios de estado ni reversiones de comisiones ya atribuidas.
CREATE FUNCTION public.validar_codigo_afiliacion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_solicitud public.solicitudes_afiliacion;
BEGIN
    IF NEW.tipo = 'comision' THEN
        SELECT * INTO v_solicitud FROM public.solicitudes_afiliacion
        WHERE id = NEW.afiliacion_id FOR SHARE;
        IF NOT FOUND OR v_solicitud.estado <> 'aprobada' OR NOT v_solicitud.codigo_activo THEN
            RAISE EXCEPTION 'La atribución requiere una afiliación aprobada con código activo'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.validar_codigo_afiliacion() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER validar_codigo_afiliacion BEFORE INSERT ON public.movimientos_comision
    FOR EACH ROW EXECUTE FUNCTION public.validar_codigo_afiliacion();

COMMENT ON FUNCTION public.resolver_solicitud_afiliacion(bigint, text, text) IS
    'V05: aprobar, rechazar o desactivar con JWT del dueño. Código propuesto opcional; sin propuesta se genera. No reactiva códigos.';
NOTIFY pgrst, 'reload schema';
COMMIT;
