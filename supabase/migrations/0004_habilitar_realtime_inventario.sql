-- ==========================================
-- 4. Habilitar Realtime para inventario y stock
-- ==========================================
-- Permite que los clientes (Desktop / Web / Móvil) reciban
-- actualizaciones en vivo por WebSocket sobre cambios en productos,
-- alertas de stock y pedidos.

ALTER TABLE public.productos REPLICA IDENTITY FULL;
ALTER TABLE public.alertas_stock REPLICA IDENTITY FULL;
ALTER TABLE public.movimientos_inventario REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'productos'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.productos;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'alertas_stock'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.alertas_stock;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'movimientos_inventario'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.movimientos_inventario;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'pedidos'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pedidos;
  END IF;
END $$;

