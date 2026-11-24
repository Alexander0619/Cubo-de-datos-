-- ============================================================
-- Streaming de PC a Oculus - Esquema COMPLETO (SQL Server 2016 SP1+)
-- Tablas + índices + catálogo + metadatos + vistas + proceso ETL.
-- Ejecutar sobre una base vacía (las tablas solas están en crear_base_de_datos.sql).
-- ============================================================
IF DB_ID(N'StreamingOculus') IS NULL
    CREATE DATABASE StreamingOculus;
GO
USE StreamingOculus;
GO

-- Dimensión: perfil del usuario
CREATE TABLE dbo.dim_usuario (
    id_perfil       INT IDENTITY(1,1) PRIMARY KEY,
    rango_edad      NVARCHAR(10) NULL CONSTRAINT CK_dim_usuario_edad CHECK (rango_edad IN (N'15-17', N'18-24', N'25-34', N'35+')),
    genero          NVARCHAR(20) NOT NULL DEFAULT (N'prefiero no decir')
                    CHECK (genero IN (N'femenino', N'masculino', N'otro', N'prefiero no decir')),
    experiencia_vr  NVARCHAR(10) NULL CHECK (experiencia_vr IN (N'ninguna', N'basica', N'frecuente'))
);
GO

-- Dimensión: ubicación
CREATE TABLE dbo.dim_ubicacion (
    id_ubicacion    INT IDENTITY(1,1) PRIMARY KEY,
    pais            NVARCHAR(60) NOT NULL,
    estado          NVARCHAR(60) NOT NULL,
    ciudad          NVARCHAR(80) NOT NULL,
    UNIQUE (pais, estado, ciudad)
);
GO

-- Dimensión: tiempo
CREATE TABLE dbo.dim_tiempo (
    id_tiempo       INT IDENTITY(1,1) PRIMARY KEY,
    fecha           DATETIME2(0) NOT NULL UNIQUE,
    anio            INT NOT NULL,
    mes             TINYINT NOT NULL CHECK (mes BETWEEN 1 AND 12),
    semana          TINYINT NOT NULL CHECK (semana BETWEEN 1 AND 53),
    dia             TINYINT NOT NULL CHECK (dia BETWEEN 1 AND 31),
    hora            TINYINT NOT NULL CHECK (hora BETWEEN 0 AND 23)
);
GO

-- Dimensión: tipo de error
CREATE TABLE dbo.dim_error (
    id_error         INT IDENTITY(1,1) PRIMARY KEY,
    categoria_error  NVARCHAR(20) NOT NULL CHECK (categoria_error IN (N'red', N'dispositivo', N'autenticacion')),
    nombre_error     NVARCHAR(60) NOT NULL UNIQUE,
    descripcion      NVARCHAR(200) NULL
);
GO

-- Tabla de login (fuera de la estrella)
-- Cuentas locales: password guarda la sal y la mitad R del secreto ("sal$R").
-- Cuentas externas (Microsoft, Google): password es NULL y se guarda id_externo.
-- encuesta_estado controla la encuesta opcional del primer uso.
CREATE TABLE dbo.usuarios (
    id_usuario      INT IDENTITY(1,1) PRIMARY KEY,
    id_perfil       INT NULL REFERENCES dbo.dim_usuario (id_perfil) ON DELETE SET NULL,
    nombre_usuario  NVARCHAR(50)  NOT NULL UNIQUE,
    email           NVARCHAR(120) NOT NULL UNIQUE,
    password        NVARCHAR(300) NULL,
    proveedor       NVARCHAR(12)  NOT NULL CONSTRAINT DF_usuarios_proveedor DEFAULT (N'local')
                    CONSTRAINT CK_usuarios_proveedor CHECK (proveedor IN (N'local', N'microsoft', N'google')),
    id_externo      NVARCHAR(128) NULL,
    encuesta_estado NVARCHAR(12)  NOT NULL CONSTRAINT DF_usuarios_encuesta DEFAULT (N'pendiente')
                    CONSTRAINT CK_usuarios_encuesta CHECK (encuesta_estado IN (N'pendiente', N'pospuesta', N'completada')),
    creado_en       DATETIME2(0)  NOT NULL CONSTRAINT DF_usuarios_creado DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_usuarios_credencial CHECK (
        (proveedor = N'local' AND password IS NOT NULL) OR (proveedor <> N'local' AND id_externo IS NOT NULL))
);
GO
CREATE UNIQUE INDEX ux_usuarios_externo ON dbo.usuarios (proveedor, id_externo) WHERE id_externo IS NOT NULL;
GO

-- Registro de aceptación de los términos (quién, cuándo y qué versión)
CREATE TABLE dbo.consentimientos (
    id_consentimiento   BIGINT IDENTITY(1,1) PRIMARY KEY,
    id_usuario          INT NULL REFERENCES dbo.usuarios (id_usuario) ON DELETE SET NULL,
    version_terminos    NVARCHAR(10) NOT NULL,
    aceptado_en         DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    segundos_en_pantalla INT NULL CHECK (segundos_en_pantalla >= 0),
    llego_al_final      BIT NULL
);
GO
CREATE UNIQUE INDEX ux_consent_usuario_version ON dbo.consentimientos (id_usuario, version_terminos) WHERE id_usuario IS NOT NULL;
GO

-- Tabla de hechos: una fila por muestra/sesión
-- id_registro permite varias muestras por dispositivo (historia para el cubo).
-- device es un seudónimo del dispositivo (dimensión degenerada), no es llave.
CREATE TABLE dbo.datos_telemetria (
    id_registro        BIGINT IDENTITY(1,1) PRIMARY KEY,
    device             NVARCHAR(64) NOT NULL,
    id_tiempo          INT NOT NULL REFERENCES dbo.dim_tiempo (id_tiempo),
    id_ubicacion       INT NOT NULL REFERENCES dbo.dim_ubicacion (id_ubicacion),
    id_perfil          INT NULL REFERENCES dbo.dim_usuario (id_perfil) ON DELETE SET NULL,
    id_error           INT NULL REFERENCES dbo.dim_error (id_error),
    latencia           FLOAT NOT NULL CHECK (latencia >= 0),
    tiempo_respuesta   FLOAT NOT NULL CHECK (tiempo_respuesta >= 0),
    paquetes_perdidos  INT NOT NULL DEFAULT (0) CHECK (paquetes_perdidos >= 0),
    controles          NVARCHAR(MAX) NULL
);
GO

-- ------------------------------------------------------------
-- Área de preparación (ETL): aquí llega la telemetría cruda de la app.
-- Sin restricciones a propósito: los datos sucios se aceptan aquí y el
-- proceso de carga los limpia o los rechaza con un motivo.
-- ------------------------------------------------------------
CREATE TABLE dbo.stg_telemetria (
    id_stg             BIGINT IDENTITY(1,1) PRIMARY KEY,
    recibido_en        DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    device             NVARCHAR(64)  NULL,
    fecha_evento       DATETIME2(0)  NULL,
    pais               NVARCHAR(60)  NULL,
    estado             NVARCHAR(60)  NULL,
    ciudad             NVARCHAR(80)  NULL,
    rango_edad         NVARCHAR(10)  NULL,
    genero             NVARCHAR(20)  NULL,
    experiencia_vr     NVARCHAR(10)  NULL,
    nombre_error       NVARCHAR(60)  NULL,
    latencia           FLOAT NULL,
    tiempo_respuesta   FLOAT NULL,
    paquetes_perdidos  INT   NULL,
    controles          NVARCHAR(MAX) NULL,
    estado_carga       NVARCHAR(12) NOT NULL DEFAULT (N'pendiente')
                       CHECK (estado_carga IN (N'pendiente', N'cargado', N'rechazado')),
    motivo_rechazo     NVARCHAR(100) NULL
);
GO

-- ------------------------------------------------------------
-- Metadatos: diccionario, jerarquías de conceptos y bitácora del ETL
-- ------------------------------------------------------------
CREATE TABLE dbo.meta_diccionario (
    id_meta          INT IDENTITY(1,1) PRIMARY KEY,
    objeto           NVARCHAR(60)  NOT NULL,   -- tabla o vista
    columna          NVARCHAR(60)  NOT NULL,
    rol              NVARCHAR(12)  NOT NULL CHECK (rol IN (N'llave', N'dimension', N'medida', N'atributo')),
    descripcion      NVARCHAR(200) NOT NULL,
    fuente           NVARCHAR(100) NULL,       -- de dónde viene el dato
    transformacion   NVARCHAR(200) NULL,       -- qué se le hace al cargarlo
    tipo_agregacion  NVARCHAR(12)  NULL CHECK (tipo_agregacion IN (N'distributiva', N'algebraica', N'holistica')),
    nivel_acceso     NVARCHAR(12)  NOT NULL CHECK (nivel_acceso IN (N'operativo', N'analitico', N'restringido')),
    UNIQUE (objeto, columna)
);
GO

CREATE TABLE dbo.meta_jerarquia (
    id_jerarquia     INT IDENTITY(1,1) PRIMARY KEY,
    dimension        NVARCHAR(30) NOT NULL,
    tipo             NVARCHAR(10) NOT NULL CHECK (tipo IN (N'esquema', N'agrupacion')),
    nivel            NVARCHAR(40) NOT NULL,
    orden            TINYINT NOT NULL,         -- 1 = nivel más detallado
    definicion       NVARCHAR(200) NULL,
    UNIQUE (dimension, tipo, orden)
);
GO

CREATE TABLE dbo.meta_etl_log (
    id_log           INT IDENTITY(1,1) PRIMARY KEY,
    ejecutado_en     DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    leidos           INT NOT NULL,
    cargados         INT NOT NULL,
    rechazados       INT NOT NULL
);
GO

-- Resumen precalculado (cuboide estado x hora) con medidas distributivas
CREATE TABLE dbo.res_calidad_estado_hora (
    estado           NVARCHAR(60) NOT NULL,
    hora             TINYINT NOT NULL,
    sesiones         INT   NOT NULL,   -- count()  distributiva
    suma_latencia    FLOAT NOT NULL,   -- sum()    distributiva
    max_latencia     FLOAT NOT NULL,   -- max()    distributiva
    suma_paquetes    INT   NOT NULL,   -- sum()    distributiva
    PRIMARY KEY (estado, hora)
);
GO

-- ------------------------------------------------------------
-- Índices de la tabla de hechos (una llave foránea = un índice)
-- ------------------------------------------------------------
CREATE INDEX ix_tel_tiempo    ON dbo.datos_telemetria (id_tiempo);
CREATE INDEX ix_tel_ubicacion ON dbo.datos_telemetria (id_ubicacion);
CREATE INDEX ix_tel_perfil    ON dbo.datos_telemetria (id_perfil);
CREATE INDEX ix_tel_error     ON dbo.datos_telemetria (id_error);
CREATE INDEX ix_stg_estado    ON dbo.stg_telemetria (estado_carga);
GO

-- ------------------------------------------------------------
-- Catálogo inicial de errores
-- ------------------------------------------------------------
INSERT INTO dbo.dim_error (categoria_error, nombre_error, descripcion) VALUES
    (N'red',           N'latencia_alta',          N'Latencia extremo a extremo por encima de la meta de 150 ms'),
    (N'red',           N'paquete_perdido',        N'Pérdida de paquetes durante la transmisión'),
    (N'red',           N'reconexion_servidor',    N'La conexión con el servidor se perdió y se restableció'),
    (N'dispositivo',   N'desconexion_bluetooth',  N'El control Xbox perdió el enlace Bluetooth con el Quest'),
    (N'dispositivo',   N'fallo_decodificacion',   N'El cliente no pudo decodificar un fragmento de video'),
    (N'autenticacion', N'credenciales_invalidas', N'Intento de inicio de sesión rechazado');
GO

-- ------------------------------------------------------------
-- Jerarquías de conceptos (metadatos). orden 1 = más detallado.
-- 'esquema'    = orden entre atributos de la dimensión
-- 'agrupacion' = valores agrupados en rangos (set-grouping)
-- ------------------------------------------------------------
INSERT INTO dbo.meta_jerarquia (dimension, tipo, nivel, orden, definicion) VALUES
    (N'tiempo',    N'esquema',    N'hora',      1, N'dim_tiempo.hora'),
    (N'tiempo',    N'esquema',    N'dia',       2, N'dim_tiempo.dia'),
    (N'tiempo',    N'esquema',    N'semana',    3, N'dim_tiempo.semana'),
    (N'tiempo',    N'esquema',    N'mes',       4, N'dim_tiempo.mes'),
    (N'tiempo',    N'esquema',    N'anio',      5, N'dim_tiempo.anio'),
    (N'ubicacion', N'esquema',    N'ciudad',    1, N'dim_ubicacion.ciudad'),
    (N'ubicacion', N'esquema',    N'estado',    2, N'dim_ubicacion.estado'),
    (N'ubicacion', N'esquema',    N'pais',      3, N'dim_ubicacion.pais'),
    (N'error',     N'esquema',    N'tipo',      1, N'dim_error.nombre_error'),
    (N'error',     N'esquema',    N'categoria', 2, N'dim_error.categoria_error'),
    (N'latencia',  N'agrupacion', N'milisegundos',      1, N'latencia (valor medido)'),
    (N'latencia',  N'agrupacion', N'rango de calidad',  2, N'excelente <50 | buena 50-99 | aceptable 100-149 | mala >=150 (meta del proyecto: 150 ms)');
GO

-- ------------------------------------------------------------
-- Diccionario de datos (metadatos). Una fila por columna relevante.
-- ------------------------------------------------------------
INSERT INTO dbo.meta_diccionario (objeto, columna, rol, descripcion, fuente, transformacion, tipo_agregacion, nivel_acceso) VALUES
    (N'datos_telemetria', N'id_registro',       N'llave',    N'Identificador de la muestra', N'Generado por la base', NULL, NULL, N'analitico'),
    (N'datos_telemetria', N'device',            N'atributo', N'Seudónimo del dispositivo (no el número de serie)', N'Cliente Flutter', N'Se reemplaza por un identificador aleatorio antes de exportar', NULL, N'restringido'),
    (N'datos_telemetria', N'latencia',          N'medida',   N'Latencia extremo a extremo en ms', N'Cliente Flutter', N'Se rechaza si es nula, negativa o mayor a 5000 ms', N'algebraica', N'analitico'),
    (N'datos_telemetria', N'tiempo_respuesta',  N'medida',   N'Tiempo entre el botón del control y el efecto en pantalla, en ms', N'Cliente Flutter', N'Se rechaza si es nulo o negativo', N'algebraica', N'analitico'),
    (N'datos_telemetria', N'paquetes_perdidos', N'medida',   N'Paquetes perdidos en la muestra', N'Servidor ASP.NET Core', N'Valores negativos se rechazan', N'distributiva', N'analitico'),
    (N'datos_telemetria', N'controles',         N'atributo', N'Estado de los controles en formato JSON', N'Cliente Flutter', N'Si no es JSON válido se guarda NULL', NULL, N'restringido'),
    (N'dim_tiempo',       N'fecha',             N'dimension',N'Fecha y hora truncada a la hora', N'Marca de tiempo del evento', N'Se trunca a la hora; semana ISO', NULL, N'analitico'),
    (N'dim_ubicacion',    N'ciudad',            N'dimension',N'Ciudad aproximada del usuario', N'Dirección IP', N'Se guarda solo ciudad; nunca la IP ni la dirección', NULL, N'analitico'),
    (N'dim_usuario',      N'rango_edad',        N'dimension',N'Rango de edad (opcional): 15-17, 18-24, 25-34, 35+', N'Encuesta opcional', N'Solo rangos, nunca fecha de nacimiento', NULL, N'analitico'),
    (N'dim_usuario',      N'genero',            N'dimension',N'Género (opcional)', N'Encuesta opcional', N'Valor por omisión: prefiero no decir', NULL, N'analitico'),
    (N'dim_usuario',      N'experiencia_vr',    N'dimension',N'Experiencia previa con realidad virtual (opcional)', N'Encuesta opcional', NULL, NULL, N'analitico'),
    (N'dim_error',        N'categoria_error',   N'dimension',N'Categoría del error: red, dispositivo o autenticación', N'Catálogo fijo', NULL, NULL, N'analitico'),
    (N'usuarios',         N'password',          N'atributo', N'Sal y mitad R del secreto de inicio de sesión', N'Registro', N'Nunca sale de la capa operativa', NULL, N'restringido'),
    (N'usuarios',         N'email',             N'atributo', N'Correo del usuario', N'Registro', N'Nunca entra al almacén analítico', NULL, N'operativo');
GO

-- ------------------------------------------------------------
-- Vista del cubo (data mart de calidad de streaming):
-- une hechos y dimensiones y agrega el rango de calidad de latencia.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW dbo.v_cubo_calidad AS
SELECT  t.id_registro, t.device,
        ti.anio, ti.mes, ti.semana, ti.dia, ti.hora,
        u.pais, u.estado, u.ciudad,
        p.rango_edad, p.genero, p.experiencia_vr,
        e.categoria_error, e.nombre_error,
        t.latencia, t.tiempo_respuesta, t.paquetes_perdidos,
        CASE WHEN t.latencia <  50  THEN N'excelente (<50)'
             WHEN t.latencia < 100  THEN N'buena (50-99)'
             WHEN t.latencia < 150  THEN N'aceptable (100-149)'
             ELSE                        N'mala (>=150)' END AS rango_latencia
FROM dbo.datos_telemetria t
JOIN dbo.dim_tiempo    ti ON ti.id_tiempo   = t.id_tiempo
JOIN dbo.dim_ubicacion u  ON u.id_ubicacion = t.id_ubicacion
LEFT JOIN dbo.dim_usuario p ON p.id_perfil  = t.id_perfil
LEFT JOIN dbo.dim_error   e ON e.id_error   = t.id_error;
GO

-- Vista para exportar a minería: SIN credenciales ni identificadores
-- (device se omite a propósito).
CREATE OR ALTER VIEW dbo.v_export_anonimo AS
SELECT  anio, mes, semana, dia, hora,
        pais, estado, ciudad,
        rango_edad, genero, experiencia_vr,
        categoria_error, nombre_error,
        latencia, tiempo_respuesta, paquetes_perdidos
FROM dbo.v_cubo_calidad;
GO

-- ------------------------------------------------------------
-- ETL: Extraer (stg) -> Limpiar -> Transformar -> Cargar -> Refrescar
-- Uso: INSERT INTO dbo.stg_telemetria (...) VALUES (...);  EXEC dbo.sp_cargar_telemetria;
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_cargar_telemetria
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @leidos INT, @cargados INT, @rechazados INT;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @leidos = COUNT(*) FROM dbo.stg_telemetria WHERE estado_carga = N'pendiente';

        -- 1) LIMPIAR: rechazar filas inservibles, con motivo
        UPDATE dbo.stg_telemetria
        SET estado_carga = N'rechazado',
            motivo_rechazo = CASE
                WHEN device IS NULL OR LTRIM(RTRIM(device)) = N''          THEN N'sin dispositivo'
                WHEN fecha_evento IS NULL                                  THEN N'sin fecha'
                WHEN fecha_evento > DATEADD(DAY, 1, SYSUTCDATETIME())      THEN N'fecha en el futuro'
                WHEN latencia IS NULL OR latencia < 0 OR latencia > 5000   THEN N'latencia fuera de rango'
                WHEN tiempo_respuesta IS NULL OR tiempo_respuesta < 0      THEN N'tiempo de respuesta invalido'
                WHEN paquetes_perdidos < 0                                 THEN N'paquetes negativos'
                WHEN pais IS NULL OR estado IS NULL OR ciudad IS NULL      THEN N'sin ubicacion'
                WHEN nombre_error IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM dbo.dim_error e WHERE e.nombre_error = stg_telemetria.nombre_error)
                                                                           THEN N'error desconocido'
            END
        WHERE estado_carga = N'pendiente'
          AND ( device IS NULL OR LTRIM(RTRIM(device)) = N''
             OR fecha_evento IS NULL OR fecha_evento > DATEADD(DAY, 1, SYSUTCDATETIME())
             OR latencia IS NULL OR latencia < 0 OR latencia > 5000
             OR tiempo_respuesta IS NULL OR tiempo_respuesta < 0
             OR paquetes_perdidos < 0
             OR pais IS NULL OR estado IS NULL OR ciudad IS NULL
             OR (nombre_error IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM dbo.dim_error e WHERE e.nombre_error = stg_telemetria.nombre_error)) );

        -- Corregir lo corregible: JSON inválido -> NULL, paquetes nulos -> 0, género vacío -> valor por omisión
        UPDATE dbo.stg_telemetria SET controles = NULL
            WHERE estado_carga = N'pendiente' AND controles IS NOT NULL AND ISJSON(controles) = 0;
        UPDATE dbo.stg_telemetria SET paquetes_perdidos = 0
            WHERE estado_carga = N'pendiente' AND paquetes_perdidos IS NULL;
        UPDATE dbo.stg_telemetria SET genero = N'prefiero no decir'
            WHERE estado_carga = N'pendiente' AND (genero IS NULL OR genero NOT IN (N'femenino', N'masculino', N'otro', N'prefiero no decir'));
        UPDATE dbo.stg_telemetria SET rango_edad = NULL
            WHERE estado_carga = N'pendiente' AND rango_edad NOT IN (N'15-17', N'18-24', N'25-34', N'35+');
        UPDATE dbo.stg_telemetria SET experiencia_vr = NULL
            WHERE estado_carga = N'pendiente' AND experiencia_vr NOT IN (N'ninguna', N'basica', N'frecuente');

        -- 2) TRANSFORMAR: completar dimensiones que aún no existen
        INSERT INTO dbo.dim_tiempo (fecha, anio, mes, semana, dia, hora)
        SELECT DISTINCT h.fecha_hora, YEAR(h.fecha_hora), MONTH(h.fecha_hora),
               DATEPART(ISO_WEEK, h.fecha_hora), DAY(h.fecha_hora), DATEPART(HOUR, h.fecha_hora)
        FROM (SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, fecha_evento), 0) AS fecha_hora
              FROM dbo.stg_telemetria WHERE estado_carga = N'pendiente') h
        WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_tiempo d WHERE d.fecha = h.fecha_hora);

        INSERT INTO dbo.dim_ubicacion (pais, estado, ciudad)
        SELECT DISTINCT s.pais, s.estado, s.ciudad
        FROM dbo.stg_telemetria s
        WHERE s.estado_carga = N'pendiente'
          AND NOT EXISTS (SELECT 1 FROM dbo.dim_ubicacion d
                          WHERE d.pais = s.pais AND d.estado = s.estado AND d.ciudad = s.ciudad);

        INSERT INTO dbo.dim_usuario (rango_edad, genero, experiencia_vr)
        SELECT DISTINCT s.rango_edad, s.genero, s.experiencia_vr
        FROM dbo.stg_telemetria s
        WHERE s.estado_carga = N'pendiente'
          AND NOT EXISTS (SELECT 1 FROM dbo.dim_usuario d
                          WHERE ISNULL(d.rango_edad, N'') = ISNULL(s.rango_edad, N'')
                            AND d.genero = s.genero
                            AND ISNULL(d.experiencia_vr, N'') = ISNULL(s.experiencia_vr, N''));

        -- 3) CARGAR: insertar los hechos con las llaves de cada dimensión
        INSERT INTO dbo.datos_telemetria
              (device, id_tiempo, id_ubicacion, id_perfil, id_error, latencia, tiempo_respuesta, paquetes_perdidos, controles)
        SELECT s.device, ti.id_tiempo, u.id_ubicacion, p.id_perfil, e.id_error,
               s.latencia, s.tiempo_respuesta, s.paquetes_perdidos, s.controles
        FROM dbo.stg_telemetria s
        JOIN dbo.dim_tiempo    ti ON ti.fecha = DATEADD(HOUR, DATEDIFF(HOUR, 0, s.fecha_evento), 0)
        JOIN dbo.dim_ubicacion u  ON u.pais = s.pais AND u.estado = s.estado AND u.ciudad = s.ciudad
        JOIN dbo.dim_usuario   p  ON ISNULL(p.rango_edad, N'') = ISNULL(s.rango_edad, N'')
                                 AND p.genero = s.genero
                                 AND ISNULL(p.experiencia_vr, N'') = ISNULL(s.experiencia_vr, N'')
        LEFT JOIN dbo.dim_error e ON e.nombre_error = s.nombre_error
        WHERE s.estado_carga = N'pendiente';
        SET @cargados = @@ROWCOUNT;

        UPDATE dbo.stg_telemetria SET estado_carga = N'cargado' WHERE estado_carga = N'pendiente';
        SET @rechazados = @leidos - @cargados;

        -- 4) REFRESCAR: resumen precalculado con medidas distributivas
        TRUNCATE TABLE dbo.res_calidad_estado_hora;
        INSERT INTO dbo.res_calidad_estado_hora (estado, hora, sesiones, suma_latencia, max_latencia, suma_paquetes)
        SELECT estado, hora, COUNT(*), SUM(latencia), MAX(latencia), SUM(paquetes_perdidos)
        FROM dbo.v_cubo_calidad
        GROUP BY estado, hora;

        INSERT INTO dbo.meta_etl_log (leidos, cargados, rechazados) VALUES (@leidos, @cargados, @rechazados);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

-- ------------------------------------------------------------
-- Encuesta opcional: guarda el perfil (rangos) y marca la encuesta como completada.
-- "prefiero no decir" en edad o experiencia se envía como NULL.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_guardar_encuesta
    @id_usuario INT, @rango_edad NVARCHAR(10) = NULL, @genero NVARCHAR(20) = NULL, @experiencia_vr NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.usuarios WHERE id_usuario = @id_usuario)
        THROW 50001, N'Usuario no encontrado', 1;
    IF @rango_edad NOT IN (N'15-17', N'18-24', N'25-34', N'35+') SET @rango_edad = NULL;
    IF @experiencia_vr NOT IN (N'ninguna', N'basica', N'frecuente') SET @experiencia_vr = NULL;
    IF @genero IS NULL OR @genero NOT IN (N'femenino', N'masculino', N'otro', N'prefiero no decir') SET @genero = N'prefiero no decir';
    BEGIN TRAN;
    DECLARE @id_perfil INT = (SELECT TOP 1 id_perfil FROM dbo.dim_usuario
        WHERE ISNULL(rango_edad, N'') = ISNULL(@rango_edad, N'') AND genero = @genero
          AND ISNULL(experiencia_vr, N'') = ISNULL(@experiencia_vr, N'') ORDER BY id_perfil);
    IF @id_perfil IS NULL
    BEGIN
        INSERT INTO dbo.dim_usuario (rango_edad, genero, experiencia_vr) VALUES (@rango_edad, @genero, @experiencia_vr);
        SET @id_perfil = SCOPE_IDENTITY();
    END
    UPDATE dbo.usuarios SET id_perfil = @id_perfil, encuesta_estado = N'completada' WHERE id_usuario = @id_usuario;
    COMMIT;
END;
GO

-- Registro de aceptación de términos (una vez por usuario y versión)
CREATE OR ALTER PROCEDURE dbo.sp_registrar_aceptacion
    @id_usuario INT, @version_terminos NVARCHAR(10), @segundos_en_pantalla INT = NULL, @llego_al_final BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.consentimientos WHERE id_usuario = @id_usuario AND version_terminos = @version_terminos)
        INSERT INTO dbo.consentimientos (id_usuario, version_terminos, segundos_en_pantalla, llego_al_final)
        VALUES (@id_usuario, @version_terminos, @segundos_en_pantalla, @llego_al_final);
END;
GO

INSERT INTO dbo.meta_diccionario (objeto, columna, rol, descripcion, fuente, transformacion, tipo_agregacion, nivel_acceso)
SELECT v.* FROM (VALUES
 (N'usuarios', N'proveedor', N'atributo', N'Origen de la cuenta: local, microsoft o google', N'Registro o inicio de sesión', NULL, NULL, N'operativo'),
 (N'usuarios', N'id_externo', N'atributo', N'Identificador de la cuenta en el proveedor externo', N'Proveedor (Microsoft/Google)', N'Nunca sale de la capa operativa', NULL, N'restringido'),
 (N'usuarios', N'encuesta_estado', N'atributo', N'Estado de la encuesta opcional: pendiente, pospuesta o completada', N'Aplicación', NULL, NULL, N'operativo'),
 (N'consentimientos', N'id_usuario', N'llave', N'Cuenta que aceptó los términos', N'Aplicación', N'Se conserva aunque se borre la cuenta (queda en NULL)', NULL, N'restringido'),
 (N'consentimientos', N'version_terminos', N'atributo', N'Versión de los términos aceptada', N'Aplicación', NULL, NULL, N'restringido'),
 (N'consentimientos', N'llego_al_final', N'atributo', N'Si la persona se desplazó hasta el final del texto', N'Aplicación', NULL, NULL, N'restringido')
) AS v (objeto, columna, rol, descripcion, fuente, transformacion, tipo_agregacion, nivel_acceso)
WHERE NOT EXISTS (SELECT 1 FROM dbo.meta_diccionario d WHERE d.objeto = v.objeto AND d.columna = v.columna);
GO
