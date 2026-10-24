-- ====================================================================
-- MIGRACIÓN 0010: Validación de modificación de perfil y protección de datos sensibles (S2-T8)
-- Tarea: S2-T8-Diego Vásquez — Validar modificación de perfil
--
-- Objetivo:
-- Garantizar en la base de datos que ningún estudiante o usuario autenticado
-- pueda modificar datos de autenticación (password_hash, auth_user_id),
-- correo institucional (email) ni su rol asignado (rol_id), asegurando además
-- la obligatoriedad y formato mínimo de nombre y apellido sin romper
-- las operaciones administrativas del Dueño ni los procesos del backend.
--
-- Idempotente: seguro de ejecutar en Supabase SQL Editor o migraciones CLI.
-- ====================================================================

CREATE OR REPLACE FUNCTION public.validar_modificacion_perfil_estudiante()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_es_dueno BOOLEAN := false;
BEGIN
    -- 1. Si la petición no proviene de un cliente autenticado (ej. service_role o migraciones), omitir
    IF (auth.role() IS NULL OR auth.role() <> 'authenticated') THEN
        NEW.actualizado_en = CURRENT_TIMESTAMP;
        RETURN NEW;
    END IF;

    -- 2. Detectar de forma segura si el usuario autenticado tiene rol 'dueño'
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'es_dueno' AND pronamespace = 'public'::regnamespace) THEN
            v_es_dueno := public.es_dueno();
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_es_dueno := false;
    END;

    -- 3. Si es Dueño/Admin, permitir gestión completa de usuarios (Desktop/KDS)
    IF v_es_dueno THEN
        NEW.actualizado_en = CURRENT_TIMESTAMP;
        RETURN NEW;
    END IF;

    -- 4. Restricciones de seguridad estrictas para estudiantes (Mobile / Web):
    -- 4.1. Impedir cambio de rol institucional
    IF NEW.rol_id IS DISTINCT FROM OLD.rol_id THEN
        RAISE EXCEPTION 'No está autorizado a modificar su rol asignado.';
    END IF;

    -- 4.2. Impedir cambio de correo institucional oficial
    IF NEW.email IS DISTINCT FROM OLD.email THEN
        RAISE EXCEPTION 'No está autorizado a modificar su correo institucional.';
    END IF;

    -- 4.3. Impedir alteración de hash de contraseña mediante actualización de perfil
    IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
        RAISE EXCEPTION 'No está permitido modificar credenciales de autenticación mediante la edición de perfil.';
    END IF;

    -- 4.4. Impedir cambio o desvinculación de auth_user_id una vez establecido
    IF OLD.auth_user_id IS NOT NULL AND NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
        RAISE EXCEPTION 'No está autorizado a transferir la vinculación de autenticación.';
    END IF;

    -- 4.5. Impedir alteración del estado de activación de la cuenta
    IF NEW.activo IS DISTINCT FROM OLD.activo THEN
        RAISE EXCEPTION 'No está autorizado a modificar el estado de la cuenta.';
    END IF;

    -- 4.6. Validaciones de formato y longitud si se modifican nombre o apellido
    IF (NEW.nombre IS DISTINCT FROM OLD.nombre) THEN
        IF char_length(trim(COALESCE(NEW.nombre, ''))) < 2 THEN
            RAISE EXCEPTION 'El nombre debe contener al menos 2 caracteres.';
        END IF;
    END IF;

    IF (NEW.apellido IS DISTINCT FROM OLD.apellido) THEN
        IF NEW.apellido IS NOT NULL AND char_length(trim(NEW.apellido)) > 0 AND char_length(trim(NEW.apellido)) < 2 THEN
            RAISE EXCEPTION 'El apellido debe contener al menos 2 caracteres.';
        END IF;
    END IF;

    -- 5. Actualizar timestamp de modificación
    NEW.actualizado_en = CURRENT_TIMESTAMP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_validar_modificacion_perfil ON public.usuarios;
CREATE TRIGGER on_validar_modificacion_perfil
    BEFORE UPDATE ON public.usuarios
    FOR EACH ROW
    EXECUTE FUNCTION public.validar_modificacion_perfil_estudiante();
