-- Consultas del cubo (SQLite). SQLite no tiene ROLLUP/CUBE ni PERCENTILE_CONT:
-- el roll-up se emula con UNION ALL y el percentil con ROW_NUMBER.
-- Cada consulta responde la misma pregunta que su versión de SQL Server.

-- 1) ROLL-UP ciudad -> estado -> total (medida algebraica: SUM/COUNT)
SELECT * FROM (
  SELECT estado, ciudad, COUNT(*) sesiones, ROUND(SUM(latencia)/COUNT(*),1) lat_prom, MAX(latencia) lat_max, SUM(paquetes_perdidos) paq, 0 nivel FROM v_cubo_calidad GROUP BY estado, ciudad
  UNION ALL SELECT estado, NULL, COUNT(*), ROUND(SUM(latencia)/COUNT(*),1), MAX(latencia), SUM(paquetes_perdidos), 1 FROM v_cubo_calidad GROUP BY estado
  UNION ALL SELECT NULL, NULL, COUNT(*), ROUND(SUM(latencia)/COUNT(*),1), MAX(latencia), SUM(paquetes_perdidos), 2 FROM v_cubo_calidad
) ORDER BY nivel = 2, estado, nivel = 0, lat_prom DESC;

-- 2) DRILL-DOWN: hora del día
SELECT hora, COUNT(*) sesiones, ROUND(AVG(latencia),1) lat_prom FROM v_cubo_calidad GROUP BY hora ORDER BY hora;

-- 3) p95 y mediana por estado (medida holística)
WITH r AS (SELECT estado, latencia, ROW_NUMBER() OVER (PARTITION BY estado ORDER BY latencia) rn, COUNT(*) OVER (PARTITION BY estado) n FROM v_cubo_calidad)
SELECT estado, MIN(CASE WHEN rn >= 0.95*n THEN latencia END) p95, MIN(CASE WHEN rn >= 0.5*n THEN latencia END) mediana
FROM r GROUP BY estado ORDER BY p95 DESC;

-- 4) SLICE: desconexiones de Bluetooth por estado y hora
SELECT estado, hora, COUNT(*) desconexiones FROM v_cubo_calidad WHERE nombre_error='desconexion_bluetooth' GROUP BY estado, hora ORDER BY desconexiones DESC LIMIT 10;

-- 5) DICE: sin experiencia VR, horario pico, 18-34 años
SELECT rango_edad, genero, COUNT(*) sesiones, ROUND(AVG(latencia),1) lat_prom, ROUND(AVG(tiempo_respuesta),1) resp_prom
FROM v_cubo_calidad WHERE experiencia_vr='ninguna' AND hora BETWEEN 20 AND 23 AND rango_edad IN ('15-17','18-24','25-34') GROUP BY rango_edad, genero;

-- 6) PIVOT: errores por categoría (columnas) contra hora (filas)
SELECT hora, SUM(categoria_error='red') red, SUM(categoria_error='dispositivo') dispositivo, SUM(categoria_error='autenticacion') autenticacion
FROM v_cubo_calidad GROUP BY hora ORDER BY hora;

-- 7) Rangos de latencia (jerarquía por agrupación)
SELECT rango_latencia, COUNT(*) sesiones, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM v_cubo_calidad),1) porcentaje
FROM v_cubo_calidad GROUP BY rango_latencia ORDER BY MIN(latencia);

-- 8) Resumen precalculado combinable (distributivas): se arma desde el detalle
CREATE TEMP TABLE res AS SELECT estado, hora, COUNT(*) sesiones, SUM(latencia) suma_lat, MAX(latencia) max_lat FROM v_cubo_calidad GROUP BY estado, hora;
SELECT estado, SUM(sesiones) sesiones, ROUND(SUM(suma_lat)/SUM(sesiones),1) lat_prom, MAX(max_lat) lat_max FROM res GROUP BY estado ORDER BY lat_prom DESC;

-- 9) k-anonimato (k=5)
SELECT rango_edad, genero, estado, ciudad, COUNT(*) sesiones FROM v_export_anonimo GROUP BY 1,2,3,4 HAVING COUNT(*) < 5 LIMIT 5;
