-- C03 · Administración de campañas de afiliados sobre public.campanas.
--
-- Integra el alta, la edición, la pausa y la reanudación con la tabla que
-- consume escritorio. No crea otra tabla, no duplica datos y no elimina
-- campañas ni aceptaciones existentes. Si una instalación local ya tiene la
-- tabla provisional campanas_afiliados, no se elimina: simplemente deja de
-- usarse.
--
-- Requiere el esquema V05 ya desplegado (migraciones 0018 y 0019 de
-- db_CoffeeFaster):
--   * public.campanas con las columnas que lee app-desktop.
--   * public.dueno_campana_id(bigint), función de identidad del dueño.
--   * public.confirmar_condiciones_campana(bigint, bigint, text).
--   * public.proteger_confirmacion_campanas() y su trigger.
--   * auth.uid().
--
-- Conserva sin cambios:
--   * public.confirmar_condiciones_campana(...), incluida su restricción de
--     vigencia: solo acepta campañas con vigencia_desde <= now() < vigencia_hasta.
--   * La prohibición de escrituras directas de authenticated/anon.
--   * La inmutabilidad de las campañas confirmadas.
--
-- Extiende de forma mínima public.proteger_confirmacion_campanas() para que
-- tasa_descuento_oferta participe en:
--   * la inmutabilidad posterior a la aceptación;
--   * la exigencia de una nueva versión al cambiar condiciones.
--
-- Preparado para revisión; NO aplicado en Supabase Cloud.
--
-- Mapeo explícito de C02 al esquema real:
--   descuento_normal_pct -> tasa_descuento
--   descuento_oferta_pct -> tasa_descuento_oferta (columna nueva, nullable)
--   comision_pct         -> tasa_comision
--   inicio               -> vigencia_desde
--   fin                  -> vigencia_hasta
--   estado "programada"  -> pendiente_aceptacion (recién creada) o aceptada.
--                           La API deriva "programada" y publica el estado
--                           real en estado_db.
--
-- Campañas existentes: tasa_descuento_oferta queda NULL. No se rellena con
-- tasa_descuento ni se modifica ninguna condición ya aceptada. NULL significa
-- que la campaña anterior no tenía un descuento separado para ofertas.
BEGIN;

DO $$
DECLARE
    faltantes text;
    tipo_oferta text;
BEGIN
    IF to_regclass('public.campanas') IS NULL THEN
        RAISE EXCEPTION 'Falta public.campanas: C03 requiere el esquema V05 existente';
    END IF;

    IF to_regprocedure('public.dueno_campana_id(bigint)') IS NULL THEN
        RAISE EXCEPTION 'Falta public.dueno_campana_id(bigint); instalar la migración V05 0019';
    END IF;

    IF to_regprocedure('public.confirmar_condiciones_campana(bigint, bigint, text)') IS NULL THEN
        RAISE EXCEPTION 'Falta public.confirmar_condiciones_campana(bigint, bigint, text); instalar la migración V05 0019';
    END IF;

    IF to_regprocedure('public.proteger_confirmacion_campanas()') IS NULL THEN
        RAISE EXCEPTION 'Falta public.proteger_confirmacion_campanas(); instalar la migración V05 0019';
    END IF;

    IF to_regprocedure('auth.uid()') IS NULL THEN
        RAISE EXCEPTION 'Falta auth.uid(); la migración debe ejecutarse en un esquema Supabase';
    END IF;

    IF to_regclass('public.usuarios') IS NULL
       OR to_regclass('public.roles') IS NULL
       OR to_regclass('public.cafeteria_usuarios') IS NULL THEN
        RAISE EXCEPTION 'Faltan public.usuarios, public.roles o public.cafeteria_usuarios para resolver la identidad del dueño';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'usuarios' AND column_name = 'auth_user_id'
    ) OR NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'usuarios' AND column_name = 'activo'
    ) THEN
        RAISE EXCEPTION 'public.usuarios debe tener auth_user_id y activo para resolver al dueño';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'roles' AND column_name = 'activo'
    ) THEN
        RAISE EXCEPTION 'public.roles debe tener activo para la identidad exacta de V05';
    END IF;

    SELECT string_agg(c, ', ' ORDER BY c) INTO faltantes
    FROM unnest(ARRAY[
        'id', 'cafeteria_id', 'nombre', 'descripcion', 'tipo', 'estado',
        'version_condiciones', 'tasa_descuento', 'tasa_comision',
        'vigencia_desde', 'vigencia_hasta', 'confirmada_por_dueno',
        'fecha_confirmacion', 'usuario_confirma_id', 'version_confirmada',
        'creado_en', 'actualizado_en'
    ]) AS c
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'campanas'
          AND column_name = c
    );
    IF faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'public.campanas no contiene las columnas del contrato de escritorio: %', faltantes;
    END IF;

    -- La migración no escribe tipo; si existe y no tiene default, debe
    -- revisarse el esquema antes de aplicarla.
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'campanas'
          AND column_name = 'tipo'
          AND is_nullable = 'NO'
          AND column_default IS NULL
    ) THEN
        RAISE EXCEPTION 'public.campanas.tipo es NOT NULL sin default; revisar el esquema antes de aplicar C03';
    END IF;

    SELECT data_type INTO tipo_oferta
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'campanas'
      AND column_name = 'tasa_descuento_oferta';

    IF tipo_oferta IS NOT NULL
       AND tipo_oferta NOT IN ('numeric', 'integer', 'bigint', 'smallint', 'real', 'double precision') THEN
        RAISE EXCEPTION 'public.campanas.tasa_descuento_oferta existe con un tipo no numérico: %', tipo_oferta;
    END IF;
END $$;

-- Columna nueva para el segundo descuento. Nullable a propósito: las campañas
-- anteriores a C03 no tenían este dato y sus condiciones aceptadas no deben
-- reinterpretarse como si el descuento normal fuera también el de oferta.
ALTER TABLE public.campanas
    ADD COLUMN IF NOT EXISTS tasa_descuento_oferta numeric(5,2);

COMMENT ON COLUMN public.campanas.tasa_descuento_oferta IS
    'Descuento de afiliado para productos en oferta. NULL en campañas anteriores a C03: no se modificó su condición aceptada.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.campanas'::regclass
          AND conname = 'campanas_tasa_oferta_rango'
    ) THEN
        ALTER TABLE public.campanas
            ADD CONSTRAINT campanas_tasa_oferta_rango
            CHECK (tasa_descuento_oferta IS NULL
                   OR (tasa_descuento_oferta >= 0 AND tasa_descuento_oferta <= 100));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.campanas'::regclass
          AND conname = 'campanas_tasa_oferta_menor_igual'
    ) THEN
        ALTER TABLE public.campanas
            ADD CONSTRAINT campanas_tasa_oferta_menor_igual
            CHECK (tasa_descuento_oferta IS NULL
                   OR tasa_descuento_oferta <= tasa_descuento);
    END IF;
END $$;

-- Versión de condiciones generada exclusivamente por el servidor.
--
-- Formato normal: incremento del componente menor de una versión numérica
-- MAJOR.MINOR (1.0 -> 1.1, 1.9 -> 1.10). Es compatible con varchar(20) y con
-- la comparación textual de V05.
--
-- Respaldo: YYYYMMDDHH24MISSUS (20 caracteres) si la versión actual no tiene
-- el formato numérico o el incremento excedería varchar(20). V05 solo exige
-- que la versión cambie; este formato también lo cumple.
CREATE OR REPLACE FUNCTION public.siguiente_version_condiciones(p_actual text)
RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actual text := btrim(coalesce(p_actual, ''));
    v_major text;
    v_minor text;
    v_nueva text;
BEGIN
    IF v_actual ~ '^[0-9]{1,9}\.[0-9]{1,9}$' THEN
        v_major := split_part(v_actual, '.', 1);
        v_minor := split_part(v_actual, '.', 2);
        v_nueva := v_major || '.' || ((v_minor::bigint + 1)::text);
        IF length(v_nueva) <= 20 AND v_nueva <> v_actual THEN
            RETURN v_nueva;
        END IF;
    END IF;

    v_nueva := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
    IF v_nueva = v_actual THEN
        v_nueva := to_char(clock_timestamp() + interval '1 microsecond', 'YYYYMMDDHH24MISSUS');
    END IF;
    RETURN v_nueva;
END;
$$;

REVOKE ALL ON FUNCTION public.siguiente_version_condiciones(text) FROM PUBLIC, anon, authenticated;

-- Extensión mínima del trigger V05 0019. Se conserva íntegra la definición
-- original y solo se agrega tasa_descuento_oferta a las dos comparaciones de
-- condiciones protegidas.
CREATE OR REPLACE FUNCTION public.proteger_confirmacion_campanas()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') THEN
        RAISE EXCEPTION 'Utilice la RPC para confirmar condiciones' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.confirmada_por_dueno AND ROW(
            NEW.cafeteria_id, NEW.nombre, NEW.descripcion, NEW.tipo, NEW.version_condiciones,
            NEW.tasa_descuento, NEW.tasa_descuento_oferta, NEW.tasa_comision,
            NEW.vigencia_desde, NEW.vigencia_hasta, NEW.confirmada_por_dueno,
            NEW.fecha_confirmacion, NEW.usuario_confirma_id, NEW.version_confirmada
        ) IS DISTINCT FROM ROW(
            OLD.cafeteria_id, OLD.nombre, OLD.descripcion, OLD.tipo, OLD.version_condiciones,
            OLD.tasa_descuento, OLD.tasa_descuento_oferta, OLD.tasa_comision,
            OLD.vigencia_desde, OLD.vigencia_hasta, OLD.confirmada_por_dueno,
            OLD.fecha_confirmacion, OLD.usuario_confirma_id, OLD.version_confirmada
        ) THEN
            RAISE EXCEPTION 'La aceptación es inmutable; cree una nueva campaña para otras condiciones'
                USING ERRCODE = '22023';
        END IF;
        IF ROW(
            NEW.nombre, NEW.descripcion, NEW.tasa_descuento, NEW.tasa_descuento_oferta,
            NEW.tasa_comision, NEW.vigencia_desde, NEW.vigencia_hasta
        ) IS DISTINCT FROM ROW(
            OLD.nombre, OLD.descripcion, OLD.tasa_descuento, OLD.tasa_descuento_oferta,
            OLD.tasa_comision, OLD.vigencia_desde, OLD.vigencia_hasta
        ) AND trim(NEW.version_condiciones) = trim(OLD.version_condiciones) THEN
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

-- Listado administrativo. Valida el alcance con la función de identidad V05 y
-- devuelve únicamente las campañas de la cafetería autorizada. No es el
-- listado estudiantil de C04.
CREATE OR REPLACE FUNCTION public.listar_campanas_afiliados(
    p_cafeteria_id bigint
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_cafeteria_id IS NULL OR p_cafeteria_id <= 0
       OR auth.uid() IS NULL
       OR public.dueno_campana_id(p_cafeteria_id) IS NULL THEN
        RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
    END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(to_jsonb(c) ORDER BY c.creado_en DESC, c.id DESC)
        FROM public.campanas c
        WHERE c.cafeteria_id = p_cafeteria_id
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.listar_campanas_afiliados(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listar_campanas_afiliados(bigint) TO authenticated;

-- Alta, edición y cambios de estado. La autorización y el bloqueo de fila se
-- resuelven en la base de datos con la sesión del dueño.
CREATE OR REPLACE FUNCTION public.administrar_campana_afiliados(
    p_cafeteria_id bigint,
    p_campana_id bigint,
    p_cambios jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_campana public.campanas;
    v_propuesta public.campanas;
    v_cambios_db jsonb := '{}'::jsonb;
    v_ahora timestamptz;
    v_es_estado boolean := false;
    v_usuario_id bigint;
    v_confirmada boolean := false;
    v_aceptada boolean := false;
    v_cambio_nombre_descripcion boolean := false;
    v_cambio_tasas boolean := false;
    v_cambio_fechas boolean := false;
    v_cambio_condiciones boolean := false;
    v_nombre_nuevo text;
    v_descripcion_nueva text;
    v_version_nueva text;
    v_estado_nuevo text;
BEGIN
    IF p_cafeteria_id IS NULL OR p_cafeteria_id <= 0 OR auth.uid() IS NULL THEN
        RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
    END IF;

    v_usuario_id := public.dueno_campana_id(p_cafeteria_id);
    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
    END IF;

    v_ahora := clock_timestamp();

    IF p_campana_id IS NOT NULL AND p_campana_id <= 0 THEN
        RAISE EXCEPTION 'campana_invalida';
    END IF;

    IF p_cambios IS NULL
       OR jsonb_typeof(p_cambios) IS DISTINCT FROM 'object'
       OR p_cambios = '{}'::jsonb THEN
        RAISE EXCEPTION 'campana_invalida';
    END IF;

    v_es_estado := p_campana_id IS NOT NULL
        AND p_cambios ? 'pausada'
        AND p_cambios - 'pausada' = '{}'::jsonb
        AND jsonb_typeof(p_cambios->'pausada') = 'boolean';

    IF p_cambios ? 'pausada' AND NOT v_es_estado THEN
        RAISE EXCEPTION 'campana_invalida';
    END IF;

    IF NOT v_es_estado THEN
        IF p_cambios - ARRAY[
            'nombre', 'descripcion', 'descuento_normal_pct',
            'descuento_oferta_pct', 'comision_pct', 'inicio', 'fin'
        ] <> '{}'::jsonb THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF p_cambios ? 'nombre' THEN
            IF jsonb_typeof(p_cambios->'nombre') <> 'string'
               OR length(btrim(p_cambios->>'nombre')) NOT BETWEEN 1 AND 150 THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'descripcion' THEN
            IF jsonb_typeof(p_cambios->'descripcion') NOT IN ('string', 'null')
               OR (jsonb_typeof(p_cambios->'descripcion') = 'string'
                   AND length(p_cambios->>'descripcion') > 2000) THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'descuento_normal_pct' THEN
            IF jsonb_typeof(p_cambios->'descuento_normal_pct') <> 'number'
               OR (p_cambios->>'descuento_normal_pct')::numeric NOT BETWEEN 0 AND 100 THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'descuento_oferta_pct' THEN
            IF jsonb_typeof(p_cambios->'descuento_oferta_pct') <> 'number'
               OR (p_cambios->>'descuento_oferta_pct')::numeric NOT BETWEEN 0 AND 100 THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'comision_pct' THEN
            IF jsonb_typeof(p_cambios->'comision_pct') <> 'number'
               OR (p_cambios->>'comision_pct')::numeric NOT BETWEEN 0 AND 100 THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'inicio' THEN
            IF jsonb_typeof(p_cambios->'inicio') <> 'string'
               OR (p_cambios->>'inicio') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_cambios ? 'fin' THEN
            IF jsonb_typeof(p_cambios->'fin') <> 'string'
               OR (p_cambios->>'fin') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
                RAISE EXCEPTION 'campana_invalida';
            END IF;
        END IF;

        IF p_campana_id IS NULL AND NOT (
            p_cambios ? 'nombre'
            AND p_cambios ? 'descuento_normal_pct'
            AND p_cambios ? 'descuento_oferta_pct'
            AND p_cambios ? 'comision_pct'
            AND p_cambios ? 'inicio'
            AND p_cambios ? 'fin'
        ) THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF p_cambios ? 'nombre' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('nombre', p_cambios->'nombre');
        END IF;
        IF p_cambios ? 'descripcion' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('descripcion', p_cambios->'descripcion');
        END IF;
        IF p_cambios ? 'descuento_normal_pct' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('tasa_descuento', p_cambios->'descuento_normal_pct');
        END IF;
        IF p_cambios ? 'descuento_oferta_pct' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('tasa_descuento_oferta', p_cambios->'descuento_oferta_pct');
        END IF;
        IF p_cambios ? 'comision_pct' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('tasa_comision', p_cambios->'comision_pct');
        END IF;
        IF p_cambios ? 'inicio' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('vigencia_desde', p_cambios->'inicio');
        END IF;
        IF p_cambios ? 'fin' THEN
            v_cambios_db := v_cambios_db || jsonb_build_object('vigencia_hasta', p_cambios->'fin');
        END IF;
    END IF;

    IF p_campana_id IS NOT NULL THEN
        SELECT * INTO v_campana
        FROM public.campanas
        WHERE id = p_campana_id AND cafeteria_id = p_cafeteria_id
        FOR UPDATE;

        IF NOT FOUND THEN
            -- Una campaña de otra cafetería se trata igual que una inexistente.
            RAISE EXCEPTION 'sin_acceso_cafeteria' USING ERRCODE = '42501';
        END IF;

        -- Se toma la hora después de adquirir el bloqueo para validar la
        -- vigencia contra el estado realmente bloqueado.
        v_ahora := clock_timestamp();

        v_confirmada := COALESCE(v_campana.confirmada_por_dueno, false);
        v_aceptada := v_confirmada
            AND btrim(COALESCE(v_campana.version_confirmada, '')) <> ''
            AND btrim(COALESCE(v_campana.version_confirmada, ''))
                = btrim(COALESCE(v_campana.version_condiciones, ''));
    END IF;

    IF NOT v_es_estado THEN
        v_propuesta := jsonb_populate_record(v_campana, v_cambios_db);

        v_nombre_nuevo := btrim(v_propuesta.nombre);
        v_descripcion_nueva := NULLIF(btrim(v_propuesta.descripcion), '');

        IF v_nombre_nuevo IS NULL
           OR length(v_nombre_nuevo) NOT BETWEEN 1 AND 150 THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF v_propuesta.tasa_descuento IS NULL
           OR v_propuesta.tasa_descuento NOT BETWEEN 0 AND 100
           OR v_propuesta.tasa_comision IS NULL
           OR v_propuesta.tasa_comision NOT BETWEEN 0 AND 100
           OR (v_propuesta.tasa_descuento_oferta IS NOT NULL
               AND v_propuesta.tasa_descuento_oferta NOT BETWEEN 0 AND 100) THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF v_propuesta.tasa_descuento_oferta IS NOT NULL
           AND v_propuesta.tasa_descuento_oferta > v_propuesta.tasa_descuento THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF v_propuesta.vigencia_desde IS NULL OR v_propuesta.vigencia_hasta IS NULL
           OR v_propuesta.vigencia_desde >= v_propuesta.vigencia_hasta THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;
    END IF;

    IF p_campana_id IS NULL THEN
        IF v_propuesta.tasa_descuento_oferta IS NULL THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        IF v_propuesta.vigencia_desde < v_ahora THEN
            RAISE EXCEPTION 'campana_invalida';
        END IF;

        INSERT INTO public.campanas (
            cafeteria_id, nombre, descripcion, estado, version_condiciones,
            tasa_descuento, tasa_descuento_oferta, tasa_comision,
            vigencia_desde, vigencia_hasta, confirmada_por_dueno,
            fecha_confirmacion, usuario_confirma_id, version_confirmada,
            creado_en, actualizado_en
        ) VALUES (
            p_cafeteria_id, v_nombre_nuevo, v_descripcion_nueva,
            'pendiente_aceptacion', '1.0',
            v_propuesta.tasa_descuento, v_propuesta.tasa_descuento_oferta,
            v_propuesta.tasa_comision,
            v_propuesta.vigencia_desde, v_propuesta.vigencia_hasta, false,
            NULL, NULL, NULL,
            v_ahora, v_ahora
        )
        RETURNING * INTO v_campana;

        RETURN to_jsonb(v_campana);
    END IF;

    IF v_es_estado THEN
        IF v_campana.estado = 'finalizada' OR v_ahora >= v_campana.vigencia_hasta THEN
            RAISE EXCEPTION 'campana_finalizada';
        END IF;

        IF (p_cambios->>'pausada')::boolean THEN
            IF v_campana.estado = 'pausada' THEN
                RETURN to_jsonb(v_campana);
            END IF;
            IF v_campana.estado NOT IN ('activa', 'aceptada') AND NOT v_aceptada THEN
                RAISE EXCEPTION 'campana_no_activa';
            END IF;
            v_estado_nuevo := 'pausada';
        ELSE
            IF NOT v_aceptada THEN
                RAISE EXCEPTION 'aceptacion_requerida';
            END IF;
            IF v_ahora < v_campana.vigencia_desde THEN
                v_estado_nuevo := 'aceptada';
            ELSE
                v_estado_nuevo := 'activa';
            END IF;
        END IF;

        UPDATE public.campanas
        SET estado = v_estado_nuevo,
            actualizado_en = clock_timestamp()
        WHERE id = v_campana.id AND cafeteria_id = p_cafeteria_id
        RETURNING * INTO v_campana;

        RETURN to_jsonb(v_campana);
    END IF;

    IF v_campana.estado = 'finalizada' OR v_ahora >= v_campana.vigencia_hasta THEN
        RAISE EXCEPTION 'campana_finalizada';
    END IF;

    v_cambio_nombre_descripcion :=
        (p_cambios ? 'nombre' AND v_nombre_nuevo IS DISTINCT FROM v_campana.nombre)
        OR (p_cambios ? 'descripcion' AND v_descripcion_nueva IS DISTINCT FROM v_campana.descripcion);

    v_cambio_tasas :=
        v_propuesta.tasa_descuento IS DISTINCT FROM v_campana.tasa_descuento
        OR v_propuesta.tasa_descuento_oferta IS DISTINCT FROM v_campana.tasa_descuento_oferta
        OR v_propuesta.tasa_comision IS DISTINCT FROM v_campana.tasa_comision;

    v_cambio_fechas :=
        v_propuesta.vigencia_desde IS DISTINCT FROM v_campana.vigencia_desde
        OR v_propuesta.vigencia_hasta IS DISTINCT FROM v_campana.vigencia_hasta;

    v_cambio_condiciones := v_cambio_nombre_descripcion OR v_cambio_tasas OR v_cambio_fechas;

    -- V05 protege todas las condiciones, no solo porcentajes y fechas.
    IF v_confirmada AND v_cambio_condiciones THEN
        RAISE EXCEPTION 'condiciones_aceptadas';
    END IF;

    -- C02 fija porcentajes y fechas desde el inicio. Nombre y descripción
    -- pueden cambiar con una nueva versión, pero no después de la aceptación.
    IF v_ahora >= v_campana.vigencia_desde AND (v_cambio_tasas OR v_cambio_fechas) THEN
        RAISE EXCEPTION 'porcentajes_fijados';
    END IF;

    IF v_cambio_fechas AND v_propuesta.vigencia_desde < v_ahora THEN
        RAISE EXCEPTION 'campana_invalida';
    END IF;

    IF v_cambio_condiciones THEN
        v_version_nueva := public.siguiente_version_condiciones(v_campana.version_condiciones);
    ELSE
        v_version_nueva := v_campana.version_condiciones;
    END IF;

    -- Solo se escriben las claves enviadas. La versión y las condiciones
    -- cambian en la misma sentencia para que el trigger V05 las vea juntas.
    UPDATE public.campanas
    SET nombre = CASE
            WHEN p_cambios ? 'nombre' THEN v_nombre_nuevo
            ELSE nombre END,
        descripcion = CASE
            WHEN p_cambios ? 'descripcion' THEN v_descripcion_nueva
            ELSE descripcion END,
        tasa_descuento = CASE
            WHEN p_cambios ? 'descuento_normal_pct' THEN v_propuesta.tasa_descuento
            ELSE tasa_descuento END,
        tasa_descuento_oferta = CASE
            WHEN p_cambios ? 'descuento_oferta_pct' THEN v_propuesta.tasa_descuento_oferta
            ELSE tasa_descuento_oferta END,
        tasa_comision = CASE
            WHEN p_cambios ? 'comision_pct' THEN v_propuesta.tasa_comision
            ELSE tasa_comision END,
        vigencia_desde = CASE
            WHEN p_cambios ? 'inicio' THEN v_propuesta.vigencia_desde
            ELSE vigencia_desde END,
        vigencia_hasta = CASE
            WHEN p_cambios ? 'fin' THEN v_propuesta.vigencia_hasta
            ELSE vigencia_hasta END,
        version_condiciones = v_version_nueva,
        actualizado_en = clock_timestamp()
    WHERE id = v_campana.id AND cafeteria_id = p_cafeteria_id
    RETURNING * INTO v_campana;

    RETURN to_jsonb(v_campana);

EXCEPTION
    -- 22023 es la regla de negocio del trigger V05: aceptación inmutable o
    -- versión nueva requerida. No es un error de infraestructura.
    WHEN SQLSTATE '22023' THEN
        IF v_confirmada THEN
            RAISE EXCEPTION 'condiciones_aceptadas';
        ELSE
            RAISE EXCEPTION 'campana_invalida';
        END IF;
    WHEN check_violation OR not_null_violation OR foreign_key_violation
      OR invalid_text_representation OR invalid_datetime_format
      OR datetime_field_overflow OR numeric_value_out_of_range
      OR datatype_mismatch THEN
        RAISE EXCEPTION 'campana_invalida';
END;
$$;

REVOKE ALL ON FUNCTION public.administrar_campana_afiliados(bigint, bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.administrar_campana_afiliados(bigint, bigint, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
