-- V04 / CAM-287. Requiere el esquema base y las migraciones 0018–0019.
BEGIN;

CREATE TABLE public.solicitudes_afiliacion (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    estudiante_id bigint NOT NULL REFERENCES public.usuarios(id) ON DELETE RESTRICT,
    campana_id bigint NOT NULL REFERENCES public.campanas(id) ON DELETE RESTRICT,
    estado text NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente', 'aprobada', 'rechazada')),
    plan_promocion text NOT NULL CHECK (plan_promocion ~ '[^[:space:]]'),
    enlace_publico text,
    codigo text,
    codigo_activo boolean NOT NULL DEFAULT false,
    resuelta_por bigint REFERENCES public.usuarios(id) ON DELETE RESTRICT,
    resuelta_en timestamptz,
    creado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    actualizado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_afiliacion_estudiante_campana UNIQUE (estudiante_id, campana_id),
    -- Un código desactivado se conserva y no vuelve a asignarse (contrato C02).
    CONSTRAINT uq_afiliacion_codigo UNIQUE (codigo),
    CONSTRAINT ck_afiliacion_codigo_formato CHECK (
        codigo IS NULL OR (length(codigo) BETWEEN 1 AND 64 AND codigo = upper(btrim(codigo)) AND codigo !~ '[[:space:]]')
    ),
    CONSTRAINT ck_afiliacion_codigo_estado CHECK (
        (estado = 'aprobada' AND codigo IS NOT NULL)
        OR (estado <> 'aprobada' AND codigo IS NULL AND NOT codigo_activo)
    ),
    CONSTRAINT ck_afiliacion_resolucion CHECK (
        (estado = 'pendiente' AND resuelta_por IS NULL AND resuelta_en IS NULL)
        OR (estado <> 'pendiente' AND resuelta_por IS NOT NULL AND resuelta_en IS NOT NULL)
    )
);
CREATE INDEX solicitudes_afiliacion_campana_estado_idx
    ON public.solicitudes_afiliacion (campana_id, estado, creado_en DESC);

CREATE TABLE public.movimientos_comision (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    afiliacion_id bigint NOT NULL REFERENCES public.solicitudes_afiliacion(id) ON DELETE RESTRICT,
    pedido_id bigint NOT NULL REFERENCES public.pedidos(id) ON DELETE RESTRICT,
    tipo text NOT NULL CHECK (tipo IN ('comision', 'reversion')),
    estado text NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente', 'disponible', 'revertida')),
    base_calculo_clp bigint NOT NULL CHECK (base_calculo_clp >= 0),
    tasa_comision numeric(5,2) NOT NULL CHECK (tasa_comision BETWEEN 0 AND 100),
    monto_clp bigint NOT NULL,
    movimiento_origen_id bigint REFERENCES public.movimientos_comision(id) ON DELETE RESTRICT,
    creado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    actualizado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_comision_pedido_tipo UNIQUE (pedido_id, tipo),
    CONSTRAINT ck_comision_evento CHECK (
        (tipo = 'comision' AND movimiento_origen_id IS NULL AND monto_clp BETWEEN 0 AND base_calculo_clp)
        OR (tipo = 'reversion' AND movimiento_origen_id IS NOT NULL AND monto_clp <= 0 AND estado = 'revertida')
    )
);
CREATE INDEX movimientos_comision_afiliacion_fecha_idx
    ON public.movimientos_comision (afiliacion_id, creado_en DESC);

-- Integridad estructural. La autorización del llamador corresponde a las RPC de V05.
CREATE FUNCTION public.validar_solicitud_afiliacion()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF ROW(NEW.id, NEW.estudiante_id, NEW.campana_id, NEW.creado_en)
            IS DISTINCT FROM ROW(OLD.id, OLD.estudiante_id, OLD.campana_id, OLD.creado_en)
            OR (OLD.codigo IS NOT NULL AND NEW.codigo IS DISTINCT FROM OLD.codigo)
            OR (OLD.estado <> 'pendiente' AND ROW(NEW.estado, NEW.resuelta_por, NEW.resuelta_en)
                IS DISTINCT FROM ROW(OLD.estado, OLD.resuelta_por, OLD.resuelta_en)) THEN
            RAISE EXCEPTION 'No se puede reemplazar la identidad, el código o la resolución de una afiliación'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        PERFORM 1 FROM public.campanas WHERE id = NEW.campana_id FOR SHARE;
        IF NOT EXISTS (
            SELECT 1 FROM public.usuarios u JOIN public.roles r ON r.id = u.rol_id
            WHERE u.id = NEW.estudiante_id AND u.activo = true AND r.activo = true AND lower(r.nombre) = 'estudiante'
        ) THEN
            RAISE EXCEPTION 'La solicitud requiere un estudiante activo' USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.estado <> 'pendiente' AND (TG_OP = 'INSERT' OR OLD.estado = 'pendiente') THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.usuarios u JOIN public.roles r ON r.id = u.rol_id
            JOIN public.cafeteria_usuarios cu ON cu.usuario_id = u.id
            JOIN public.campanas c ON c.cafeteria_id = cu.cafeteria_id
            WHERE u.id = NEW.resuelta_por AND u.activo = true AND r.activo = true
              AND lower(r.nombre) IN ('dueño', 'dueno') AND c.id = NEW.campana_id
        ) THEN
            RAISE EXCEPTION 'La resolución requiere un dueño activo de la cafetería' USING ERRCODE = '23514';
        END IF;
    END IF;
    NEW.actualizado_en := clock_timestamp();
    RETURN NEW;
END;
$$;
CREATE TRIGGER validar_solicitud_afiliacion BEFORE INSERT OR UPDATE ON public.solicitudes_afiliacion
    FOR EACH ROW EXECUTE FUNCTION public.validar_solicitud_afiliacion();

CREATE FUNCTION public.validar_movimiento_comision()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
    v_origen public.movimientos_comision;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (to_jsonb(NEW) - 'estado' - 'actualizado_en')
            IS DISTINCT FROM (to_jsonb(OLD) - 'estado' - 'actualizado_en')
            OR (NEW.estado <> OLD.estado AND NOT (
                OLD.tipo = 'comision' AND OLD.estado = 'pendiente' AND NEW.estado IN ('disponible', 'revertida')
            )) THEN
            RAISE EXCEPTION 'Los importes y referencias históricos son inmutables' USING ERRCODE = '23514';
        END IF;
    ELSE
        PERFORM 1 FROM public.pedidos WHERE id = NEW.pedido_id FOR SHARE;
        IF NOT EXISTS (
            SELECT 1 FROM public.solicitudes_afiliacion s
            JOIN public.campanas c ON c.id = s.campana_id
            JOIN public.pedidos p ON p.id = NEW.pedido_id AND p.cafeteria_id = c.cafeteria_id
            WHERE s.id = NEW.afiliacion_id AND s.estado = 'aprobada'
        ) THEN
            RAISE EXCEPTION 'El pedido y la afiliación aprobada deben pertenecer a la misma cafetería'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.tipo = 'comision' AND NEW.estado <> 'pendiente' THEN
            RAISE EXCEPTION 'La comisión se registra primero como pendiente' USING ERRCODE = '23514';
        END IF;
        IF NEW.tipo = 'reversion' THEN
            SELECT * INTO v_origen FROM public.movimientos_comision WHERE id = NEW.movimiento_origen_id;
            IF NOT FOUND OR v_origen.tipo <> 'comision' OR v_origen.estado <> 'revertida'
                OR ROW(NEW.afiliacion_id, NEW.pedido_id, NEW.base_calculo_clp, NEW.tasa_comision, NEW.monto_clp)
                    IS DISTINCT FROM ROW(v_origen.afiliacion_id, v_origen.pedido_id,
                        v_origen.base_calculo_clp, v_origen.tasa_comision, -v_origen.monto_clp) THEN
                RAISE EXCEPTION 'La reversión debe compensar exactamente su comisión original'
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;
    NEW.actualizado_en := clock_timestamp();
    RETURN NEW;
END;
$$;
CREATE TRIGGER validar_movimiento_comision BEFORE INSERT OR UPDATE ON public.movimientos_comision
    FOR EACH ROW EXECUTE FUNCTION public.validar_movimiento_comision();

-- V09 marcará el original e insertará la compensación en la misma transacción;
-- nunca se confirma solo la mitad de la reversión.
CREATE FUNCTION public.comprobar_reversion_comision()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_original public.movimientos_comision;
BEGIN
    SELECT * INTO v_original FROM public.movimientos_comision
    WHERE id = CASE WHEN NEW.tipo = 'reversion' THEN NEW.movimiento_origen_id ELSE NEW.id END;
    IF FOUND AND (v_original.estado = 'revertida') IS DISTINCT FROM EXISTS (
        SELECT 1 FROM public.movimientos_comision WHERE movimiento_origen_id = v_original.id
    ) THEN
        RAISE EXCEPTION 'La comisión revertida y su compensación deben confirmarse juntas'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER comprobar_reversion_comision AFTER INSERT OR UPDATE ON public.movimientos_comision
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.comprobar_reversion_comision();

-- Impedir que una edición del padre desplace datos históricos a otra cafetería.
CREATE FUNCTION public.proteger_ambito_afiliaciones()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.cafeteria_id IS DISTINCT FROM OLD.cafeteria_id AND (
        (TG_TABLE_NAME = 'campanas' AND EXISTS (SELECT 1 FROM public.solicitudes_afiliacion WHERE campana_id = OLD.id))
        OR (TG_TABLE_NAME = 'pedidos' AND EXISTS (SELECT 1 FROM public.movimientos_comision WHERE pedido_id = OLD.id))
    ) THEN
        RAISE EXCEPTION 'No se puede cambiar la cafetería de un registro con historial de afiliación'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER proteger_ambito_afiliaciones BEFORE UPDATE OF cafeteria_id ON public.campanas
    FOR EACH ROW EXECUTE FUNCTION public.proteger_ambito_afiliaciones();
CREATE TRIGGER proteger_ambito_afiliaciones BEFORE UPDATE OF cafeteria_id ON public.pedidos
    FOR EACH ROW EXECUTE FUNCTION public.proteger_ambito_afiliaciones();

CREATE FUNCTION public.estudiante_afiliacion_id()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT u.id FROM public.usuarios u JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid() AND u.activo = true AND r.activo = true AND lower(r.nombre) = 'estudiante'
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.estudiante_afiliacion_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.estudiante_afiliacion_id() TO authenticated;
REVOKE ALL ON FUNCTION public.validar_solicitud_afiliacion(), public.validar_movimiento_comision(),
    public.comprobar_reversion_comision(), public.proteger_ambito_afiliaciones()
    FROM PUBLIC, anon, authenticated;

ALTER TABLE public.solicitudes_afiliacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_comision ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.solicitudes_afiliacion, public.movimientos_comision FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.solicitudes_afiliacion, public.movimientos_comision TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.solicitudes_afiliacion, public.movimientos_comision TO service_role;

CREATE POLICY solicitudes_afiliacion_lectura ON public.solicitudes_afiliacion FOR SELECT TO authenticated
    USING (
        estudiante_id = (SELECT public.estudiante_afiliacion_id())
        OR EXISTS (SELECT 1 FROM public.campanas c WHERE c.id = solicitudes_afiliacion.campana_id
            AND public.dueno_campana_id(c.cafeteria_id) IS NOT NULL)
    );
CREATE POLICY movimientos_comision_lectura ON public.movimientos_comision FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.solicitudes_afiliacion s WHERE s.id = movimientos_comision.afiliacion_id));

COMMENT ON TABLE public.solicitudes_afiliacion IS
    'Una solicitud por estudiante y campaña; código global único, reservado incluso tras desactivación.';
COMMENT ON TABLE public.movimientos_comision IS
    'Comisiones y reversiones en CLP con referencias e importes históricos; no son movimientos de la Wallet de compra.';

NOTIFY pgrst, 'reload schema';
COMMIT;
