-- ============================================================
-- Consultas del cubo de calidad de streaming (SQL Server)
-- Cada consulta responde una pregunta que el equipo necesita contestar.
-- Todas leen la vista v_cubo_calidad (hechos + dimensiones).
-- GROUPING(col) vale 1 cuando el NULL de esa columna es un total.
-- ============================================================
USE StreamingOculus;
GO

-- 1) ROLL-UP (ciudad -> estado -> total):
--    ¿Qué estados y ciudades tienen peor latencia?
--    La latencia promedio es una medida ALGEBRAICA: SUM() / COUNT().
SELECT  estado, ciudad,
        COUNT(*)                                   AS sesiones,
        ROUND(SUM(latencia) / COUNT(*), 1)         AS latencia_prom_ms,
        MAX(latencia)                              AS latencia_max_ms,
        SUM(paquetes_perdidos)                     AS paquetes_perdidos,
        GROUPING(estado) AS es_total_general, GROUPING(ciudad) AS es_subtotal_estado
FROM dbo.v_cubo_calidad
GROUP BY ROLLUP (estado, ciudad)
ORDER BY GROUPING(estado), estado, GROUPING(ciudad), latencia_prom_ms DESC;
GO

-- 2) DRILL-DOWN (año -> mes -> hora):
--    ¿A qué horas del día se degrada la transmisión?
SELECT  anio, mes, hora,
        COUNT(*) AS sesiones,
        ROUND(AVG(latencia), 1) AS latencia_prom_ms
FROM dbo.v_cubo_calidad
GROUP BY ROLLUP (anio, mes, hora)
ORDER BY anio, mes, hora;
GO

-- 3) MEDIDA HOLÍSTICA: percentil 95 de latencia por estado.
--    No se puede calcular combinando subtotales (no es distributiva ni algebraica),
--    por eso se calcula siempre desde el detalle.
SELECT DISTINCT
        estado,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latencia) OVER (PARTITION BY estado), 1) AS latencia_p95_ms,
        ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY latencia) OVER (PARTITION BY estado), 1) AS latencia_mediana_ms
FROM dbo.v_cubo_calidad
ORDER BY latencia_p95_ms DESC;
GO

-- 4) SLICE (una dimensión fija): solo sesiones con desconexión de Bluetooth.
--    ¿Dónde y a qué horas se cae el control?
SELECT  estado, hora, COUNT(*) AS desconexiones
FROM dbo.v_cubo_calidad
WHERE nombre_error = N'desconexion_bluetooth'
GROUP BY estado, hora
ORDER BY desconexiones DESC;
GO

-- 5) DICE (varias dimensiones fijas): usuarios nuevos en VR, en horario pico.
--    ¿Mejora o empeora la experiencia para quien apenas empieza?
SELECT  rango_edad, genero,
        COUNT(*) AS sesiones,
        ROUND(AVG(latencia), 1)         AS latencia_prom_ms,
        ROUND(AVG(tiempo_respuesta), 1) AS respuesta_prom_ms
FROM dbo.v_cubo_calidad
WHERE experiencia_vr = N'ninguna'
  AND hora BETWEEN 20 AND 23
  AND rango_edad IN (N'18-24', N'25-34')
GROUP BY rango_edad, genero;
GO

-- 6) PIVOT (rotar ejes): errores por categoría (columnas) contra hora (filas).
--    ¿Los fallos de la noche son de red o del dispositivo?
SELECT  hora,
        SUM(CASE WHEN categoria_error = N'red'           THEN 1 ELSE 0 END) AS red,
        SUM(CASE WHEN categoria_error = N'dispositivo'   THEN 1 ELSE 0 END) AS dispositivo,
        SUM(CASE WHEN categoria_error = N'autenticacion' THEN 1 ELSE 0 END) AS autenticacion
FROM dbo.v_cubo_calidad
GROUP BY hora
ORDER BY hora;
GO

-- 7) JERARQUÍA POR AGRUPACIÓN (rangos de latencia) contra categoría de error.
--    ¿Qué parte de las sesiones cumple la meta de 150 ms?
SELECT  rango_latencia,
        COUNT(*) AS sesiones,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS porcentaje
FROM dbo.v_cubo_calidad
GROUP BY rango_latencia
ORDER BY MIN(latencia);
GO

-- 8) CUBE: todas las combinaciones de estado y rango de edad (todos los cuboides).
SELECT  estado, rango_edad,
        COUNT(*) AS sesiones,
        ROUND(AVG(latencia), 1) AS latencia_prom_ms
FROM dbo.v_cubo_calidad
GROUP BY CUBE (estado, rango_edad);
GO

-- 9) USO DEL RESUMEN PRECALCULADO: promedio por estado combinando subtotales
--    de medidas distributivas (SUM y COUNT), sin recorrer los hechos.
SELECT  estado,
        SUM(sesiones)                                   AS sesiones,
        ROUND(SUM(suma_latencia) / SUM(sesiones), 1)    AS latencia_prom_ms,
        MAX(max_latencia)                               AS latencia_max_ms
FROM dbo.res_calidad_estado_hora
GROUP BY estado
ORDER BY latencia_prom_ms DESC;
GO

-- 10) VERIFICACIÓN DE K-ANONIMATO (k = 5) antes de exportar:
--     combinaciones con MENOS de 5 sesiones (si devuelve filas, fusionar o excluir).
SELECT  rango_edad, genero, estado, ciudad, COUNT(*) AS sesiones
FROM dbo.v_export_anonimo
GROUP BY rango_edad, genero, estado, ciudad
HAVING COUNT(*) < 5;
GO

-- 11) BITÁCORA DEL ETL: ¿cuántas filas se rechazaron y por qué?
SELECT motivo_rechazo, COUNT(*) AS filas
FROM dbo.stg_telemetria
WHERE estado_carga = N'rechazado'
GROUP BY motivo_rechazo
ORDER BY filas DESC;
GO
