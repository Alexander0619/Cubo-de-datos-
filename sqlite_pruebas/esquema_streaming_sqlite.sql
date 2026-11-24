-- ============================================================
-- Streaming de PC a Oculus - Esquema de base de datos (SQLite)
-- Almacén de datos con esquema en estrella + tabla de login
-- ============================================================
-- IMPORTANTE: SQLite no activa las llaves foráneas por defecto.
-- Ejecutar esta línea en CADA conexión (en EF Core/Microsoft.Data.Sqlite
-- se activa con "Foreign Keys=True" en la cadena de conexión).
PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- Dimensión: perfil del usuario (todo opcional, solo rangos)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_usuario (
    id_perfil       INTEGER PRIMARY KEY AUTOINCREMENT,
    rango_edad      TEXT CHECK (rango_edad IN ('15-17', '18-24', '25-34', '35+')),
    genero          TEXT NOT NULL DEFAULT 'prefiero no decir'
                    CHECK (genero IN ('femenino', 'masculino', 'otro', 'prefiero no decir')),
    experiencia_vr  TEXT CHECK (experiencia_vr IN ('ninguna', 'basica', 'frecuente'))
);

-- ------------------------------------------------------------
-- Dimensión: ubicación (jerarquía país > estado > ciudad)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_ubicacion (
    id_ubicacion    INTEGER PRIMARY KEY AUTOINCREMENT,
    pais            TEXT NOT NULL,
    estado          TEXT NOT NULL,
    ciudad          TEXT NOT NULL,
    UNIQUE (pais, estado, ciudad)
);

-- ------------------------------------------------------------
-- Dimensión: tiempo (jerarquía año > mes > semana > día > hora)
-- fecha en formato ISO 'YYYY-MM-DD HH:MM:SS'
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tiempo (
    id_tiempo       INTEGER PRIMARY KEY AUTOINCREMENT,
    fecha           TEXT NOT NULL UNIQUE,
    anio            INTEGER NOT NULL,
    mes             INTEGER NOT NULL CHECK (mes BETWEEN 1 AND 12),
    semana          INTEGER NOT NULL CHECK (semana BETWEEN 1 AND 53),
    dia             INTEGER NOT NULL CHECK (dia BETWEEN 1 AND 31),
    hora            INTEGER NOT NULL CHECK (hora BETWEEN 0 AND 23)
);

-- ------------------------------------------------------------
-- Dimensión: tipo de error (jerarquía categoría > tipo)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_error (
    id_error         INTEGER PRIMARY KEY AUTOINCREMENT,
    categoria_error  TEXT NOT NULL CHECK (categoria_error IN ('red', 'dispositivo', 'autenticacion')),
    nombre_error     TEXT NOT NULL UNIQUE,
    descripcion      TEXT
);

-- ------------------------------------------------------------
-- Tabla de login (fuera de la estrella)
-- password guarda la mitad del secreto del servidor (R) y la sal,
-- p. ej. "sal_base64$R_base64". La otra mitad (L) vive solo en el
-- dispositivo (flutter_secure_storage) y NUNCA se guarda aquí.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuarios (
    id_usuario      INTEGER PRIMARY KEY AUTOINCREMENT,
    id_perfil       INTEGER REFERENCES dim_usuario (id_perfil) ON DELETE SET NULL,
    nombre_usuario  TEXT NOT NULL UNIQUE,
    email           TEXT NOT NULL UNIQUE,
    password        TEXT,
    proveedor       TEXT NOT NULL DEFAULT 'local' CHECK (proveedor IN ('local','microsoft','google')),
    id_externo      TEXT,
    encuesta_estado TEXT NOT NULL DEFAULT 'pendiente' CHECK (encuesta_estado IN ('pendiente','pospuesta','completada')),
    creado_en       TEXT DEFAULT (datetime('now')),
    CHECK ((proveedor='local' AND password IS NOT NULL) OR (proveedor<>'local' AND id_externo IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_usuarios_externo ON usuarios (proveedor, id_externo) WHERE id_externo IS NOT NULL;

CREATE TABLE IF NOT EXISTS consentimientos (
    id_consentimiento    INTEGER PRIMARY KEY AUTOINCREMENT,
    id_usuario           INTEGER REFERENCES usuarios (id_usuario) ON DELETE SET NULL,
    version_terminos     TEXT NOT NULL,
    aceptado_en          TEXT NOT NULL DEFAULT (datetime('now')),
    segundos_en_pantalla INTEGER,
    llego_al_final       INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_consent_usuario_version ON consentimientos (id_usuario, version_terminos) WHERE id_usuario IS NOT NULL;

-- ------------------------------------------------------------
-- Tabla de hechos: una fila por muestra/sesión (id_registro permite varias por dispositivo)
CREATE TABLE IF NOT EXISTS datos_telemetria (
    id_registro        INTEGER PRIMARY KEY AUTOINCREMENT,
    device             TEXT NOT NULL,
    id_tiempo          INTEGER NOT NULL REFERENCES dim_tiempo (id_tiempo),
    id_ubicacion       INTEGER NOT NULL REFERENCES dim_ubicacion (id_ubicacion),
    id_perfil          INTEGER REFERENCES dim_usuario (id_perfil) ON DELETE SET NULL,
    id_error           INTEGER REFERENCES dim_error (id_error),
    latencia           REAL    NOT NULL CHECK (latencia >= 0),
    tiempo_respuesta   REAL    NOT NULL CHECK (tiempo_respuesta >= 0),
    paquetes_perdidos  INTEGER NOT NULL DEFAULT 0 CHECK (paquetes_perdidos >= 0),
    controles          TEXT
);

CREATE TABLE IF NOT EXISTS stg_telemetria (
    id_stg INTEGER PRIMARY KEY AUTOINCREMENT,
    device TEXT, fecha_evento TEXT, pais TEXT, estado TEXT, ciudad TEXT,
    rango_edad TEXT, genero TEXT, experiencia_vr TEXT, nombre_error TEXT,
    latencia REAL, tiempo_respuesta REAL, paquetes_perdidos INTEGER, controles TEXT,
    estado_carga TEXT NOT NULL DEFAULT 'pendiente', motivo_rechazo TEXT
);

CREATE INDEX IF NOT EXISTS ix_tel_tiempo    ON datos_telemetria (id_tiempo);
CREATE INDEX IF NOT EXISTS ix_tel_ubicacion ON datos_telemetria (id_ubicacion);
CREATE INDEX IF NOT EXISTS ix_tel_perfil    ON datos_telemetria (id_perfil);
CREATE INDEX IF NOT EXISTS ix_tel_error     ON datos_telemetria (id_error);

-- ------------------------------------------------------------
-- Catálogo inicial de errores
-- ------------------------------------------------------------
INSERT OR IGNORE INTO dim_error (categoria_error, nombre_error, descripcion) VALUES
    ('red',           'latencia_alta',         'Latencia extremo a extremo por encima de la meta de 150 ms'),
    ('red',           'paquete_perdido',       'Pérdida de paquetes durante la transmisión'),
    ('red',           'reconexion_servidor',   'La conexión con el servidor se perdió y se restableció'),
    ('dispositivo',   'desconexion_bluetooth', 'El control Xbox perdió el enlace Bluetooth con el Quest'),
    ('dispositivo',   'fallo_decodificacion',  'El cliente no pudo decodificar un fragmento de video'),
    ('autenticacion', 'credenciales_invalidas','Intento de inicio de sesión rechazado');

-- ------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_cubo_calidad AS
SELECT  t.id_registro, t.device,
        ti.anio, ti.mes, ti.semana, ti.dia, ti.hora,
        u.pais, u.estado, u.ciudad,
        p.rango_edad, p.genero, p.experiencia_vr,
        e.categoria_error, e.nombre_error,
        t.latencia, t.tiempo_respuesta, t.paquetes_perdidos,
        CASE WHEN t.latencia <  50  THEN 'excelente (<50)'
             WHEN t.latencia < 100  THEN 'buena (50-99)'
             WHEN t.latencia < 150  THEN 'aceptable (100-149)'
             ELSE 'mala (>=150)' END AS rango_latencia
FROM datos_telemetria t
JOIN dim_tiempo    ti ON ti.id_tiempo   = t.id_tiempo
JOIN dim_ubicacion u  ON u.id_ubicacion = t.id_ubicacion
LEFT JOIN dim_usuario p ON p.id_perfil  = t.id_perfil
LEFT JOIN dim_error   e ON e.id_error   = t.id_error;

CREATE VIEW IF NOT EXISTS v_export_anonimo AS
SELECT anio, mes, semana, dia, hora, pais, estado, ciudad,
       rango_edad, genero, experiencia_vr, categoria_error, nombre_error,
       latencia, tiempo_respuesta, paquetes_perdidos
FROM v_cubo_calidad;
