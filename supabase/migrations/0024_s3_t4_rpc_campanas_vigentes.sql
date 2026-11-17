-- S3-T4: ajusta la RPC de 0023 para devolver únicamente campañas vigentes.
-- 0023 pudo haberse aplicado en otros entornos; se conserva su firma y el
-- retorno con estado_vigencia para no romper consumidores. CREATE OR REPLACE
-- exige el mismo tipo de retorno, por eso el cambio va en una migración nueva.
BEGIN;

CREATE OR REPLACE FUNCTION public.listar_oportunidades_campana(p_cafeteria_id bigint)
RETURNS TABLE (
    id bigint,
    nombre varchar(150),
    cafeteria_id bigint,
    cafeteria_nombre text,
    tipo varchar(50),
    estado varchar(30),
    vigencia_desde timestamptz,
    vigencia_hasta timestamptz,
    tasa_descuento numeric(5,2),
    tasa_comision numeric(5,2),
    estado_vigencia text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Se requiere una sesión autenticada' USING ERRCODE = '42501';
    END IF;
    IF p_cafeteria_id IS NULL OR p_cafeteria_id <= 0 THEN
        RAISE EXCEPTION 'p_cafeteria_id debe ser un entero positivo' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.usuarios u
        JOIN public.roles r ON r.id = u.rol_id
        WHERE u.auth_user_id = auth.uid() AND u.activo = true
          AND r.activo = true AND lower(r.nombre) = 'estudiante'
    ) THEN
        RAISE EXCEPTION 'Se requiere una cuenta activa de estudiante' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT c.id, c.nombre, c.cafeteria_id, caf.nombre::text, c.tipo, c.estado,
           c.vigencia_desde, c.vigencia_hasta, c.tasa_descuento, c.tasa_comision,
           'en_curso'::text
    FROM public.campanas c
    JOIN public.cafeterias caf ON caf.id = c.cafeteria_id
    WHERE c.cafeteria_id = p_cafeteria_id
      AND caf.activa IS TRUE
      AND c.estado = 'activa'
      AND c.vigencia_desde <= statement_timestamp()
      AND c.vigencia_hasta > statement_timestamp()
    ORDER BY c.vigencia_desde, c.id;
END;
$$;

REVOKE ALL ON FUNCTION public.listar_oportunidades_campana(bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_oportunidades_campana(bigint) TO authenticated;
COMMENT ON FUNCTION public.listar_oportunidades_campana(bigint) IS
    'S3-T4: lista campañas vigentes y activas de una cafetería activa para estudiantes activos. Vigente: inicio <= hora de consulta < fin. Conserva estado_vigencia = en_curso por compatibilidad con 0023.';

NOTIFY pgrst, 'reload schema';
COMMIT;
