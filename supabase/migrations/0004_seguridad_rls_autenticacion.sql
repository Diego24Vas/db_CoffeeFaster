-- ==========================================
-- MIGRACIÓN: SEGURIDAD, RLS Y AUTENTICACIÓN
-- ==========================================
-- Cumple con: FR-01, FR-02, NFR-04, NFR-09, NFR-10, BR-06 del SRS
-- Roles según SRS: estudiante, empleado, dueño
-- ==========================================

-- ==========================================
-- PASO 1: INSERTAR ROLES SEGÚN SRS
-- ==========================================

INSERT INTO roles (nombre, descripcion) VALUES
    ('estudiante', 'Consulta menús, realiza pedidos, paga y retira con QR via Android'),
    ('empleado', 'Opera el KDS en Windows para preparar y validar retiros QR'),
    ('dueño', 'Administra productos, stock, personal, métricas y recibe alertas de IA')
ON CONFLICT (nombre) DO NOTHING;

-- ==========================================
-- PASO 2: AGREGAR CAMPO auth_user_id A USUARIOS
-- ==========================================
-- Vincula la tabla usuarios con el sistema de autenticación de Supabase

ALTER TABLE usuarios ADD COLUMN auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX idx_usuarios_auth_user_id ON usuarios(auth_user_id);

COMMENT ON COLUMN usuarios.auth_user_id IS 'UUID del usuario en auth.users para vincular con Supabase Auth (FR-01)';

-- ==========================================
-- PASO 3: HABILITAR RLS EN TODAS LAS TABLAS
-- ==========================================

ALTER TABLE universidades ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE metodos_pago ENABLE ROW LEVEL SECURITY;
ALTER TABLE campus_sedes ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE cafeterias ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispositivos ENABLE ROW LEVEL SECURITY;
ALTER TABLE productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE cafeteria_usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE alertas_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimientos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE detalles_pedido ENABLE ROW LEVEL SECURITY;
ALTER TABLE pagos ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs_validacion_qr ENABLE ROW LEVEL SECURITY;

-- ==========================================
-- PASO 4: POLÍTICAS RLS PARA TABLAS PÚBLICAS
-- ==========================================

-- universidades: lectura pública, escritura solo dueño
CREATE POLICY "universidades_select_public" ON universidades
    FOR SELECT USING (true);

CREATE POLICY "universidades_insert_dueno" ON universidades
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

CREATE POLICY "universidades_update_dueno" ON universidades
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

CREATE POLICY "universidades_delete_dueno" ON universidades
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- roles: solo lectura para authenticated, nadie puede modificar
CREATE POLICY "roles_select_authenticated" ON roles
    FOR SELECT USING (auth.role() = 'authenticated');

-- categorias: lectura pública
CREATE POLICY "categorias_select_public" ON categorias
    FOR SELECT USING (true);

-- metodos_pago: lectura pública
CREATE POLICY "metodos_pago_select_public" ON metodos_pago
    FOR SELECT USING (true);

-- ==========================================
-- PASO 5: POLÍTICAS RLS PARA USUARIOS (FR-02)
-- ==========================================

-- Los usuarios pueden ver su propio perfil
CREATE POLICY "usuarios_select_own" ON usuarios
    FOR SELECT USING (
        auth_user_id = auth.uid()
    );

-- Los dueños pueden ver todos los usuarios (FR-14)
CREATE POLICY "usuarios_select_dueno" ON usuarios
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- Los usuarios pueden actualizar su propio perfil
CREATE POLICY "usuarios_update_own" ON usuarios
    FOR UPDATE USING (
        auth_user_id = auth.uid()
    ) WITH CHECK (
        auth_user_id = auth.uid()
    );

-- Solo dueño puede insertar usuarios (FR-14)
CREATE POLICY "usuarios_insert_dueno" ON usuarios
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- Solo dueño puede eliminar usuarios
CREATE POLICY "usuarios_delete_dueno" ON usuarios
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- ==========================================
-- PASO 6: POLÍTICAS RLS PARA CAMPUS_SEDES
-- ==========================================

CREATE POLICY "campus_sedes_select_public" ON campus_sedes
    FOR SELECT USING (true);

CREATE POLICY "campus_sedes_insert_dueno" ON campus_sedes
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

CREATE POLICY "campus_sedes_update_dueno" ON campus_sedes
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

CREATE POLICY "campus_sedes_delete_dueno" ON campus_sedes
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- ==========================================
-- PASO 7: POLÍTICAS RLS PARA CAFETERIAS
-- ==========================================

CREATE POLICY "cafeterias_select_public" ON cafeterias
    FOR SELECT USING (true);

CREATE POLICY "cafeterias_all_dueno" ON cafeterias
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- ==========================================
-- PASO 8: POLÍTICAS RLS PARA PRODUCTOS (FR-11, FR-12, FR-13)
-- ==========================================

-- Lectura pública de productos activos
CREATE POLICY "productos_select_public" ON productos
    FOR SELECT USING (activo = true);

-- Dueño puede todo con productos
CREATE POLICY "productos_all_dueno" ON productos
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- Empleado puede ver productos de su cafetería
CREATE POLICY "productos_select_empleado" ON productos
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'empleado'
            AND cu.cafeteria_id = productos.cafeteria_id
        )
    );

-- ==========================================
-- PASO 9: POLÍTICAS RLS PARA CAFETERIA_USUARIOS (FR-14)
-- ==========================================

-- Dueño puede todo (gestionar empleados)
CREATE POLICY "cafeteria_usuarios_all_dueno" ON cafeteria_usuarios
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- Los usuarios pueden ver su propia asignación
CREATE POLICY "cafeteria_usuarios_select_own" ON cafeteria_usuarios
    FOR SELECT USING (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

-- ==========================================
-- PASO 10: POLÍTICAS RLS PARA PEDIDOS
-- ==========================================

-- Los estudiantes ven sus propios pedidos
CREATE POLICY "pedidos_select_own" ON pedidos
    FOR SELECT USING (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

-- Dueño ve pedidos de su cafetería (BR-06)
CREATE POLICY "pedidos_select_dueno" ON pedidos
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND cu.cafeteria_id = pedidos.cafeteria_id
        )
    );

-- Empleado ve pedidos de su cafetería (para KDS)
CREATE POLICY "pedidos_select_empleado" ON pedidos
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'empleado'
            AND cu.cafeteria_id = pedidos.cafeteria_id
        )
    );

-- Los estudiantes autenticados pueden crear pedidos (FR-03, FR-04)
CREATE POLICY "pedidos_insert_estudiante" ON pedidos
    FOR INSERT WITH CHECK (
        auth.role() = 'authenticated'
        AND usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

-- ==========================================
-- PASO 11: POLÍTICAS RLS PARA DETALLES_PEDIDO
-- ==========================================

-- Los estudiantes ven detalles de sus pedidos
CREATE POLICY "detalles_pedido_select_own" ON detalles_pedido
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM pedidos p
            WHERE p.id = detalles_pedido.pedido_id
            AND p.usuario_id = (
                SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
            )
        )
    );

-- Dueño y empleado ven detalles de pedidos de su cafetería
CREATE POLICY "detalles_pedido_select_dueno_empleado" ON detalles_pedido
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM pedidos p
            JOIN cafeteria_usuarios cu ON cu.cafeteria_id = p.cafeteria_id
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre IN ('dueño', 'empleado')
            AND p.id = detalles_pedido.pedido_id
        )
    );

-- ==========================================
-- PASO 12: POLÍTICAS RLS PARA PAGOS
-- ==========================================

-- Los estudiantes ven sus propios pagos
CREATE POLICY "pagos_select_own" ON pagos
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM pedidos p
            WHERE p.id = pagos.pedido_id
            AND p.usuario_id = (
                SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
            )
        )
    );

-- Dueño ve pagos de su cafetería (BR-06)
CREATE POLICY "pagos_select_dueno" ON pagos
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM pedidos p
            JOIN cafeteria_usuarios cu ON cu.cafeteria_id = p.cafeteria_id
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND p.id = pagos.pedido_id
        )
    );

-- ==========================================
-- PASO 13: POLÍTICAS RLS PARA DISPOSITIVOS
-- ==========================================

CREATE POLICY "dispositivos_select_own" ON dispositivos
    FOR SELECT USING (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

CREATE POLICY "dispositivos_insert_own" ON dispositivos
    FOR INSERT WITH CHECK (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

CREATE POLICY "dispositivos_update_own" ON dispositivos
    FOR UPDATE USING (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    ) WITH CHECK (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

CREATE POLICY "dispositivos_delete_own" ON dispositivos
    FOR DELETE USING (
        usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

-- ==========================================
-- PASO 14: POLÍTICAS RLS PARA ALERTAS_STOCK (FR-19)
-- ==========================================

-- Dueño ve alertas de su cafetería
CREATE POLICY "alertas_stock_select_dueno" ON alertas_stock
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND cu.cafeteria_id = alertas_stock.cafeteria_id
        )
    );

-- Dueño puede gestionar alertas
CREATE POLICY "alertas_stock_manage_dueno" ON alertas_stock
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND cu.cafeteria_id = alertas_stock.cafeteria_id
        )
    );

-- ==========================================
-- PASO 15: POLÍTICAS RLS PARA MOVIMIENTOS_INVENTARIO
-- ==========================================

-- Dueño ve movimientos de su cafetería
CREATE POLICY "movimientos_inventario_select_dueno" ON movimientos_inventario
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM productos p
            JOIN cafeteria_usuarios cu ON cu.cafeteria_id = p.cafeteria_id
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND p.id = movimientos_inventario.producto_id
        )
    );

-- Dueño y empleado pueden insertar movimientos
CREATE POLICY "movimientos_inventario_insert_dueno_empleado" ON movimientos_inventario
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM productos p
            JOIN cafeteria_usuarios cu ON cu.cafeteria_id = p.cafeteria_id
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre IN ('dueño', 'empleado')
            AND p.id = movimientos_inventario.producto_id
        )
        AND usuario_id = (
            SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
        )
    );

-- ==========================================
-- PASO 16: POLÍTICAS RLS PARA LOGS_VALIDACION_QR (BR-03, BR-08)
-- ==========================================

-- Dueño ve logs de su cafetería
CREATE POLICY "logs_validacion_qr_select_dueno" ON logs_validacion_qr
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
            AND cu.cafeteria_id = logs_validacion_qr.cafeteria_id
        )
    );

-- Empleado puede insertar logs (para validar QR)
CREATE POLICY "logs_validacion_qr_insert_empleado" ON logs_validacion_qr
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM cafeteria_usuarios cu
            JOIN usuarios u ON u.id = cu.usuario_id
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'empleado'
            AND cu.cafeteria_id = logs_validacion_qr.cafeteria_id
        )
    );

-- ==========================================
-- PASO 17: FUNCIÓN SEGURA PARA CAMBIAR ESTADO PEDIDO (FR-08)
-- ==========================================

CREATE OR REPLACE FUNCTION cambiar_estado_pedido(
    p_pedido_id BIGINT,
    p_nuevo_estado VARCHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_estado_actual VARCHAR;
    v_creado_en TIMESTAMP;
    v_cafeteria_id BIGINT;
    v_usuario_id BIGINT;
    v_rol_nombre VARCHAR;
    v_tiene_permiso BOOLEAN;
BEGIN
    -- 1. VERIFICAR AUTENTICACIÓN (FR-01, NFR-04)
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Error de autenticación: Debe estar autenticado para realizar esta operación.';
    END IF;

    -- 2. Obtener ID del usuario en nuestra tabla
    SELECT id INTO v_usuario_id
    FROM usuarios
    WHERE auth_user_id = auth.uid();

    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'Usuario no encontrado en el sistema.';
    END IF;

    -- 3. Obtener datos actuales del pedido y bloquear la fila
    SELECT estado, creado_en, cafeteria_id
    INTO v_estado_actual, v_creado_en, v_cafeteria_id
    FROM pedidos
    WHERE id = p_pedido_id FOR UPDATE;

    -- 4. Validar que el pedido exista
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido con ID % no existe.', p_pedido_id;
    END IF;

    -- 5. VERIFICAR ROL Y PERMISOS (FR-02, BR-06)
    SELECT r.nombre INTO v_rol_nombre
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.id = v_usuario_id;

    -- Verificar permisos según el rol
    v_tiene_permiso := FALSE;

    IF v_rol_nombre = 'dueño' THEN
        -- Dueño tiene acceso total (BR-06)
        v_tiene_permiso := TRUE;

    ELSIF v_rol_nombre = 'empleado' THEN
        -- Empleado puede cambiar estados en su cafetería (FR-08)
        IF p_nuevo_estado IN ('preparando', 'listo') THEN
            SELECT EXISTS(
                SELECT 1 FROM cafeteria_usuarios cu
                WHERE cu.usuario_id = v_usuario_id
                AND cu.cafeteria_id = v_cafeteria_id
                AND cu.gestiona_pedidos_kds = true
            ) INTO v_tiene_permiso;
        END IF;
    END IF;

    -- Si no tiene permiso, denegar (FR-02)
    IF NOT v_tiene_permiso THEN
        RAISE EXCEPTION 'Error de autorización: No tiene permisos para realizar esta operación. Rol: %', v_rol_nombre;
    END IF;

    -- 6. Prevenir cambios ilógicos (BR-04)
    IF v_estado_actual IN ('entregado', 'cancelado') THEN
        RAISE EXCEPTION 'Operación rechazada: El pedido ya está en estado final (%).', v_estado_actual;
    END IF;

    -- 7. Validar transiciones de estado permitidas (FR-08)
    IF v_estado_actual = 'pendiente' AND p_nuevo_estado NOT IN ('preparando', 'cancelado') THEN
        RAISE EXCEPTION 'Transición no permitida: De pendiente solo se puede cambiar a preparando o cancelado.';
    END IF;

    IF v_estado_actual = 'preparando' AND p_nuevo_estado NOT IN ('listo', 'cancelado') THEN
        RAISE EXCEPTION 'Transición no permitida: De preparando solo se puede cambiar a listo o cancelado.';
    END IF;

    IF v_estado_actual = 'listo' AND p_nuevo_estado NOT IN ('entregado') THEN
        RAISE EXCEPTION 'Transición no permitida: De listo solo se puede cambiar a entregado.';
    END IF;

    -- 8. Ejecutar el cambio de estado
    IF p_nuevo_estado = 'preparando' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            inicio_preparacion_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'listo' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            listo_en = CURRENT_TIMESTAMP,
            tiempo_real_min = ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_creado_en)) / 60)::INTEGER
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'entregado' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            entregado_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSIF p_nuevo_estado = 'cancelado' THEN
        UPDATE pedidos
        SET estado = p_nuevo_estado,
            cancelado_en = CURRENT_TIMESTAMP
        WHERE id = p_pedido_id;

    ELSE
        RAISE EXCEPTION 'Estado no reconocido: %', p_nuevo_estado;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;

COMMENT ON FUNCTION cambiar_estado_pedido IS 'Función segura que cambia el estado de un pedido con verificación de autenticación (FR-01) y autorización por roles (FR-02). Usa SECURITY INVOKER para respetar RLS.';

-- ==========================================
-- PASO 18: FUNCIONES DE UTILIDAD PARA AUTENTICACIÓN
-- ==========================================

-- Función para obtener el rol del usuario actual
CREATE OR REPLACE FUNCTION get_user_role()
RETURNS VARCHAR AS $$
DECLARE
    v_rol VARCHAR;
BEGIN
    SELECT r.nombre INTO v_rol
    FROM usuarios u
    JOIN roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid();

    RETURN v_rol;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_user_role IS 'Retorna el rol del usuario actualmente autenticado (FR-02)';

-- Función para obtener el ID del usuario actual
CREATE OR REPLACE FUNCTION get_current_user_id()
RETURNS BIGINT AS $$
BEGIN
    RETURN (
        SELECT id FROM usuarios WHERE auth_user_id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_current_user_id IS 'Retorna el ID del usuario en la tabla usuarios para el usuario autenticado actual';

-- Funciones de verificación de roles (FR-02)
CREATE OR REPLACE FUNCTION is_estudiante()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (get_user_role() = 'estudiante');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION is_empleado()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (get_user_role() = 'empleado');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION is_dueno()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (get_user_role() = 'dueño');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ==========================================
-- PASO 19: SISTEMA DE LOGS DE AUDITORÍA (NFR-09, NFR-10)
-- ==========================================
-- Requisitos: logs estructurados JSON de eventos críticos, retención 30 días

-- Tabla de logs de auditoría del sistema
CREATE TABLE IF NOT EXISTS logs_auditoria (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE SET NULL,
    auth_user_id UUID,
    tipo_evento VARCHAR(50) NOT NULL,
    tabla_afectada VARCHAR(100),
    registro_id BIGINT,
    accion VARCHAR(50) NOT NULL,
    datos_anteriores JSONB,
    datos_nuevos JSONB,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB,
    creado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Habilitar RLS en logs
ALTER TABLE logs_auditoria ENABLE ROW LEVEL SECURITY;

-- Solo dueño puede ver logs (NFR-09)
CREATE POLICY "logs_auditoria_select_dueno" ON logs_auditoria
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM usuarios u
            JOIN roles r ON r.id = u.rol_id
            WHERE u.auth_user_id = auth.uid()
            AND r.nombre = 'dueño'
        )
    );

-- Índices para retención y consultas
CREATE INDEX idx_logs_auditoria_creado_en ON logs_auditoria(creado_en);
CREATE INDEX idx_logs_auditoria_tipo_evento ON logs_auditoria(tipo_evento);
CREATE INDEX idx_logs_auditoria_usuario_id ON logs_auditoria(usuario_id);

COMMENT ON TABLE logs_auditoria IS 'Logs de auditoría del sistema para eventos críticos (NFR-09). Retención mínima 30 días (NFR-10).';

-- ==========================================
-- PASO 20: FUNCIONES DE LOGGING (NFR-09)
-- ==========================================

-- Función para registrar eventos de autenticación
CREATE OR REPLACE FUNCTION log_auth_event(
    p_tipo_evento VARCHAR,
    p_auth_user_id UUID,
    p_metadata JSONB DEFAULT NULL
) RETURNS void AS $$
DECLARE
    v_usuario_id BIGINT;
BEGIN
    SELECT id INTO v_usuario_id
    FROM usuarios
    WHERE auth_user_id = p_auth_user_id;

    INSERT INTO logs_auditoria (
        usuario_id,
        auth_user_id,
        tipo_evento,
        tabla_afectada,
        accion,
        metadata
    ) VALUES (
        v_usuario_id,
        p_auth_user_id,
        p_tipo_evento,
        'auth',
        p_tipo_evento,
        p_metadata
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION log_auth_event IS 'Registra eventos de autenticación: login, logout, signup (NFR-09)';

-- Función para registrar cambios en pedidos
CREATE OR REPLACE FUNCTION log_pedido_change(
    p_usuario_id BIGINT,
    p_pedido_id BIGINT,
    p_estado_anterior VARCHAR,
    p_estado_nuevo VARCHAR
) RETURNS void AS $$
BEGIN
    INSERT INTO logs_auditoria (
        usuario_id,
        tipo_evento,
        tabla_afectada,
        registro_id,
        accion,
        datos_anteriores,
        datos_nuevos
    ) VALUES (
        p_usuario_id,
        'cambio_estado_pedido',
        'pedidos',
        p_pedido_id,
        'update',
        jsonb_build_object('estado', p_estado_anterior),
        jsonb_build_object('estado', p_estado_nuevo)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION log_pedido_change IS 'Registra cambios de estado de pedidos (NFR-09)';

-- Función para registrar validaciones QR (BR-03, BR-08)
CREATE OR REPLACE FUNCTION log_qr_validation(
    p_cafeteria_id BIGINT,
    p_usuario_id BIGINT,
    p_pedido_id BIGINT,
    p_resultado VARCHAR,
    p_motivo_rechazo TEXT DEFAULT NULL
) RETURNS void AS $$
BEGIN
    INSERT INTO logs_validacion_qr (
        cafeteria_id,
        usuario_id,
        pedido_id,
        resultado,
        motivo_rechazo
    ) VALUES (
        p_cafeteria_id,
        p_usuario_id,
        p_pedido_id,
        p_resultado,
        p_motivo_rechazo
    );

    -- También registrar en logs de auditoría
    INSERT INTO logs_auditoria (
        usuario_id,
        tipo_evento,
        tabla_afectada,
        registro_id,
        accion,
        metadata
    ) VALUES (
        p_usuario_id,
        'validacion_qr',
        'logs_validacion_qr',
        p_pedido_id,
        p_resultado,
        jsonb_build_object(
            'cafeteria_id', p_cafeteria_id,
            'resultado', p_resultado,
            'motivo_rechazo', p_motivo_rechazo
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION log_qr_validation IS 'Registra validaciones de QR con resultado (BR-03, BR-08, NFR-09)';

-- ==========================================
-- PASO 21: TRIGGERS DE AUDITORÍA (NFR-09)
-- ==========================================

-- Trigger para cambios en pedidos
CREATE OR REPLACE FUNCTION trigger_log_pedido_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.estado IS DISTINCT FROM NEW.estado THEN
        PERFORM log_pedido_change(
            NEW.usuario_id,
            NEW.id,
            OLD.estado,
            NEW.estado
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_pedido_estado_changed
    AFTER UPDATE ON pedidos
    FOR EACH ROW
    EXECUTE FUNCTION trigger_log_pedido_change();

-- Trigger para sincronizar auth_user_id
CREATE OR REPLACE FUNCTION sync_user_auth_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.email_confirmed_at IS NOT NULL AND OLD.email_confirmed_at IS NULL THEN
        UPDATE usuarios
        SET auth_user_id = NEW.id
        WHERE email = NEW.email
        AND auth_user_id IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION sync_user_auth_id();

-- ==========================================
-- PASO 22: FUNCIÓN DE RETENCIÓN DE LOGS (NFR-10)
-- ==========================================
-- Retención mínima de 30 días

CREATE OR REPLACE FUNCTION cleanup_old_logs()
RETURNS void AS $$
BEGIN
    -- Eliminar logs de auditoría mayores a 30 días
    DELETE FROM logs_auditoria
    WHERE creado_en < CURRENT_TIMESTAMP - INTERVAL '30 days';

    -- Eliminar logs de validación QR mayores a 30 días
    DELETE FROM logs_validacion_qr
    WHERE creado_en < CURRENT_TIMESTAMP - INTERVAL '30 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_old_logs IS 'Elimina logs mayores a 30 días para cumplir retención (NFR-10)';

-- ==========================================
-- PASO 23: GRANTS PARA FUNCIONES PÚBLICAS
-- ==========================================

GRANT EXECUTE ON FUNCTION get_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION get_current_user_id() TO authenticated;
GRANT EXECUTE ON FUNCTION is_estudiante() TO authenticated;
GRANT EXECUTE ON FUNCTION is_empleado() TO authenticated;
GRANT EXECUTE ON FUNCTION is_dueno() TO authenticated;
GRANT EXECUTE ON FUNCTION cambiar_estado_pedido(BIGINT, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION log_auth_event(VARCHAR, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION log_pedido_change(BIGINT, BIGINT, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION log_qr_validation(BIGINT, BIGINT, BIGINT, VARCHAR, TEXT) TO authenticated;
