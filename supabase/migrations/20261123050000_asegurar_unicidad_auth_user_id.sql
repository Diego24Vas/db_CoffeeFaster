-- Las instalaciones nuevas ya reciben esta restricción en 0001.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint AS constraint_info
    JOIN pg_attribute AS column_info
      ON column_info.attrelid = constraint_info.conrelid
     AND constraint_info.conkey = ARRAY[column_info.attnum]
    WHERE constraint_info.conrelid = 'public.usuarios'::regclass
      AND constraint_info.contype = 'u'
      AND column_info.attname = 'auth_user_id'
      AND NOT column_info.attisdropped
  ) THEN
    ALTER TABLE public.usuarios
      ADD CONSTRAINT usuarios_auth_user_id_key UNIQUE (auth_user_id);
  END IF;
END;
$$;
