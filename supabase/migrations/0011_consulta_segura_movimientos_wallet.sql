-- ====================================================================
-- MIGRACIÓN 0011: Consulta segura de movimientos de Wallet y Realtime (S2-T12)
-- Tarea: S2-T12-Diego Vásquez — Integrar consulta segura de movimientos
--
-- Objetivo:
-- 1. Garantizar que la consulta de movimientos esté estrictamente aislada
--    a nivel de base de datos (RLS), asegurando que un usuario autenticado
--    únicamente pueda consultar los movimientos pertenecientes a su propia Wallet.
-- 2. Asegurar idempotencia y compatibilidad total con la plataforma Supabase.
-- 3. Optimizar el índice compuesto (wallet_id, creado_en DESC) para la app móvil.
-- 4. Habilitar la publicación en supabase_realtime para la tabla movimientos_wallet,
--    permitiendo a la app móvil recibir eventos INSERT en tiempo real.
--
-- Idempotente: seguro de ejecutar en Supabase SQL Editor o migraciones CLI.
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. SEGURIDAD A NIVEL DE FILA (RLS) EN movimientos_wallet
-- --------------------------------------------------------------------
ALTER TABLE public.movimientos_wallet ENABLE ROW LEVEL SECURITY;

-- Conceder permisos de lectura a usuarios autenticados (filtrados por RLS)
GRANT SELECT ON TABLE public.movimientos_wallet TO authenticated;

-- Revocar explícitamente cualquier acceso anónimo a los movimientos
REVOKE ALL ON TABLE public.movimientos_wallet FROM anon;

-- --------------------------------------------------------------------
-- 2. POLÍTICA RLS ESTRICTA POR USUARIO Y WALLET
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS movimientos_wallet_select_own ON public.movimientos_wallet;
CREATE POLICY movimientos_wallet_select_own ON public.movimientos_wallet
    FOR SELECT TO authenticated
    USING (
        wallet_id IN (
            SELECT w.id FROM public.wallets w WHERE w.usuario_id = public.mi_usuario_id()
        )
        OR (
            EXISTS (
                SELECT 1 FROM pg_proc WHERE proname = 'es_dueno' AND pronamespace = 'public'::regnamespace
            ) AND public.es_dueno()
        )
    );

-- --------------------------------------------------------------------
-- 3. PROTECCIÓN CONTRA MUTACIÓN DIRECTA DESDE EL CLIENTE
-- --------------------------------------------------------------------
-- Los movimientos únicamente se crean a través de RPCs seguras (recargar_saldo,
-- procesar_pago, cancelar_pedido). Se asegura que no existan políticas de escritura.
DROP POLICY IF EXISTS movimientos_wallet_insert_client ON public.movimientos_wallet;
DROP POLICY IF EXISTS movimientos_wallet_update_client ON public.movimientos_wallet;
DROP POLICY IF EXISTS movimientos_wallet_delete_client ON public.movimientos_wallet;

-- --------------------------------------------------------------------
-- 4. ÍNDICE COMPUESTO DE RENDIMIENTO PARA LA APP MÓVIL
-- --------------------------------------------------------------------
-- Acelera las consultas con filtro de wallet_id y ordenamiento descendente por fecha:
CREATE INDEX IF NOT EXISTS idx_movimientos_wallet_wallet_creado
    ON public.movimientos_wallet (wallet_id, creado_en DESC);

-- --------------------------------------------------------------------
-- 5. HABILITAR PUBLICACIÓN REALTIME
-- --------------------------------------------------------------------
-- Permite que la app móvil reciba notificaciones instantáneas ante nuevos movimientos:
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime' AND tablename = 'movimientos_wallet'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.movimientos_wallet;
            RAISE NOTICE 'Tabla movimientos_wallet agregada a supabase_realtime';
        END IF;
    END IF;
END $$;
