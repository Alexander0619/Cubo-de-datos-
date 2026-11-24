-- ============================================================
-- 05 Migración (idempotente) para una base StreamingOculus ya creada
-- con el esquema anterior. Si instaló la versión nueva de 01_esquema_completo.sql
-- NO necesita este script (se puede ejecutar igual: no repite cambios).
-- Cambios: rango de edad 15-17, proveedores y encuesta en usuarios,
-- tabla consentimientos, procedimientos de encuesta y aceptación.
-- ============================================================
USE StreamingOculus;
GO

-- 1) Rango de edad 15-17 en dim_usuario (se busca el CHECK actual aunque no tenga nombre)
DECLARE @ck SYSNAME, @sql NVARCHAR(400);
SELECT @ck = name FROM sys.check_constraints
 WHERE parent_object_id = OBJECT_ID(N'dbo.dim_usuario') AND definition LIKE N'%rango_edad%';
IF @ck IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID(N'dbo.dim_usuario') AND definition LIKE N'%rango_edad%' AND definition LIKE N'%15-17%')
BEGIN
    SET @sql = N'ALTER TABLE dbo.dim_usuario DROP CONSTRAINT ' + QUOTENAME(@ck);
    EXEC (@sql);
    SET @ck = NULL;
END
IF @ck IS NULL
    ALTER TABLE dbo.dim_usuario ADD CONSTRAINT CK_dim_usuario_edad
        CHECK (rango_edad IN (N'15-17', N'18-24', N'25-34', N'35+'));
GO

-- 2) usuarios: contraseña opcional (cuentas externas) y columnas nuevas
ALTER TABLE dbo.usuarios ALTER COLUMN password NVARCHAR(300) NULL;
GO
IF COL_LENGTH(N'dbo.usuarios', N'proveedor') IS NULL
    ALTER TABLE dbo.usuarios ADD proveedor NVARCHAR(12) NOT NULL CONSTRAINT DF_usuarios_proveedor DEFAULT (N'local');
IF COL_LENGTH(N'dbo.usuarios', N'id_externo') IS NULL
    ALTER TABLE dbo.usuarios ADD id_externo NVARCHAR(128) NULL;
IF COL_LENGTH(N'dbo.usuarios', N'encuesta_estado') IS NULL
    ALTER TABLE dbo.usuarios ADD encuesta_estado NVARCHAR(12) NOT NULL CONSTRAINT DF_usuarios_encuesta DEFAULT (N'pendiente');
IF COL_LENGTH(N'dbo.usuarios', N'creado_en') IS NULL
    ALTER TABLE dbo.usuarios ADD creado_en DATETIME2(0) NOT NULL CONSTRAINT DF_usuarios_creado DEFAULT (SYSUTCDATETIME());
GO
IF OBJECT_ID(N'dbo.CK_usuarios_proveedor') IS NULL
    ALTER TABLE dbo.usuarios ADD CONSTRAINT CK_usuarios_proveedor CHECK (proveedor IN (N'local', N'microsoft', N'google'));
IF OBJECT_ID(N'dbo.CK_usuarios_encuesta') IS NULL
    ALTER TABLE dbo.usuarios ADD CONSTRAINT CK_usuarios_encuesta CHECK (encuesta_estado IN (N'pendiente', N'pospuesta', N'completada'));
IF OBJECT_ID(N'dbo.CK_usuarios_credencial') IS NULL
    ALTER TABLE dbo.usuarios ADD CONSTRAINT CK_usuarios_credencial CHECK (
        (proveedor = N'local' AND password IS NOT NULL) OR (proveedor <> N'local' AND id_externo IS NOT NULL));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_usuarios_externo' AND object_id = OBJECT_ID(N'dbo.usuarios'))
    CREATE UNIQUE INDEX ux_usuarios_externo ON dbo.usuarios (proveedor, id_externo) WHERE id_externo IS NOT NULL;
GO

-- 3) Registro de aceptación de términos
IF OBJECT_ID(N'dbo.consentimientos', N'U') IS NULL
CREATE TABLE dbo.consentimientos (
    id_consentimiento   BIGINT IDENTITY(1,1) PRIMARY KEY,
    id_usuario          INT NULL REFERENCES dbo.usuarios (id_usuario) ON DELETE SET NULL,
    version_terminos    NVARCHAR(10) NOT NULL,
    aceptado_en         DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    segundos_en_pantalla INT NULL CHECK (segundos_en_pantalla >= 0),
    llego_al_final      BIT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_consent_usuario_version' AND object_id = OBJECT_ID(N'dbo.consentimientos'))
    CREATE UNIQUE INDEX ux_consent_usuario_version ON dbo.consentimientos (id_usuario, version_terminos) WHERE id_usuario IS NOT NULL;
GO

-- 4) El ETL debe aceptar el rango 15-17 (se corrige el texto del procedimiento existente)
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.sp_cargar_telemetria'));
IF @def IS NOT NULL AND @def NOT LIKE N'%15-17%'
BEGIN
    SET @def = REPLACE(@def, N'rango_edad NOT IN (N''18-24'', N''25-34'', N''35+'')', N'rango_edad NOT IN (N''15-17'', N''18-24'', N''25-34'', N''35+'')');
    SET @def = REPLACE(@def, N'CREATE PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
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
