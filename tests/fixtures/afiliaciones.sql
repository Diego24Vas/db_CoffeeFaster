-- Datos propios de los runners de V04/V05. Nunca se aplica sobre una base existente.
DO $$ BEGIN
    IF current_database() !~ '^cf_(v0[45]|oportunidades(?:_upgrade)?)_test_[0-9]+_[0-9]+$' THEN
        RAISE EXCEPTION 'El fixture requiere una base temporal cf_v04_test_*, cf_v05_test_*, cf_oportunidades_test_* o cf_oportunidades_upgrade_test_*';
    END IF;
END $$;

INSERT INTO public.roles(id, nombre) VALUES (1, 'estudiante'), (2, 'empleado'), (3, 'dueño');
INSERT INTO public.cafeterias(id, nombre) VALUES (1, 'Cafetería A — prueba V04'), (2, 'Cafetería B — prueba V04');
INSERT INTO auth.users(id)
SELECT ('00000000-0000-0000-0000-' || lpad(id::text, 12, '0'))::uuid
FROM unnest(ARRAY[1, 3, 4, 10, 11, 12, 13, 14, 20]) AS id;
INSERT INTO public.usuarios(id, rol_id, nombre, email, password_hash, activo, auth_user_id)
SELECT id, CASE WHEN id IN (1,3) THEN 3 WHEN id = 4 THEN 2 ELSE 1 END,
    'Cuenta ficticia ' || id, 'v04-' || id || '@example.invalid', 'sin-login-de-prueba', id <> 12,
    ('00000000-0000-0000-0000-' || lpad(id::text, 12, '0'))::uuid
FROM unnest(ARRAY[1, 3, 4, 10, 11, 12, 13, 14, 20]) AS id;
INSERT INTO public.cafeteria_usuarios(usuario_id, cafeteria_id) VALUES (1,1), (3,2), (4,1);
INSERT INTO public.campanas(id, cafeteria_id, nombre, estado, version_condiciones, tasa_comision, vigencia_desde, vigencia_hasta)
OVERRIDING SYSTEM VALUE VALUES
    (1,1,'Campaña A — prueba V04','activa','1.0',10,now()-interval '1 day',now()+interval '10 days'),
    (2,2,'Campaña B — prueba V04','activa','1.0',5,now()-interval '1 day',now()+interval '10 days');
INSERT INTO public.pedidos(id, usuario_id, cafeteria_id, estado, pago_estado, total) VALUES
    (201,20,1,'pendiente','pagado',10000), (202,20,2,'pendiente','pagado',10000),
    (203,11,1,'pendiente','pagado',8000), (204,20,1,'pendiente','pagado',8000);

INSERT INTO public.solicitudes_afiliacion(id, estudiante_id, campana_id, plan_promocion, estado, codigo, codigo_activo, resuelta_por, resuelta_en)
OVERRIDING SYSTEM VALUE VALUES
    (101,10,1,'Plan pendiente de prueba','pendiente',NULL,false,NULL,NULL),
    (102,14,1,'Plan rechazado de prueba','rechazada',NULL,false,1,now()),
    (103,10,2,'Plan aprobado B','aprobada','OTRA-10',true,3,now()),
    (104,11,1,'Plan aprobado A','aprobada','CAFE-11',true,1,now()),
    (105,11,2,'Otro plan aprobado B','aprobada','OTRA-11',true,3,now());
INSERT INTO public.movimientos_comision(id, afiliacion_id, pedido_id, tipo, base_calculo_clp, tasa_comision, monto_clp)
OVERRIDING SYSTEM VALUE VALUES (301,104,201,'comision',10000,10,1000), (302,105,202,'comision',10000,5,500);

CREATE FUNCTION public.test_assert(ok boolean, mensaje text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FALLO: %', mensaje; END IF; END $$;
CREATE FUNCTION public.test_rechaza(sentencia text, codigo text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN EXECUTE sentencia;
    EXCEPTION WHEN OTHERS THEN IF SQLSTATE = codigo THEN RETURN; END IF; RAISE; END;
    RAISE EXCEPTION 'FALLO: se permitió %', sentencia;
END $$;
