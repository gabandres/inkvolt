# Novedades de Inkvolt Print para Mac

El español de WHATS-NEW.md: el «Novedades de esta versión» del App Store en español (es-MX) de cada actualización sale de
estas notas (`localizations` › `es-MX` › `whatsNew` de `assets/store/listing.json`, que `asc-listing.mjs apply` envía si la
versión ya tiene esa localización en App Store Connect). Los mismos encabezados en el mismo orden y una línea por cada
línea en inglés: cada línea que se agregue a WHATS-NEW.md necesita aquí su español (`PdfStringsTests` lo comprueba).

## Next

## 1.3
- Inkvolt Print habla español: toda la app, sus alertas y sus mensajes siguen el idioma que elijas para ella en macOS (Configuración del Sistema › General › Idioma y región › Aplicaciones) o en Configuración › Idioma.
- Acceso SNMP: una impresora que solo responde por SNMP y cuyo administrador cambió su comunidad de lectura se puede agregar con esa comunidad (Agregar una impresora › ¿Sabes su dirección? › Acceso SNMP) y cambiarla después (Acceso SNMP… en el menú de la impresora en la barra lateral). Se guarda en tu llavero y solo se usa para leer la impresora.
- SNMPv3: los mismos campos de Acceso SNMP aceptan el usuario SNMPv3 de una impresora y sus dos frases de contraseña (autenticación SHA-256, privacidad AES-128). Cada solicitud va firmada y cifrada y solo lee, y si el nombre de usuario o una frase de contraseña no es correcto, se indica cuál (una función de Inkvolt Pro, gratis por ahora).
- Un PDF dañado que envía un escáner ya no detiene ni congela Inkvolt Print, y un historial de tinta y tóner muy largo se abre rápido.
- Una página escaneada demasiado grande para editarla (más de 300 millones de píxeles) se guarda tal como la envió el escáner, y su nota dice que no se enderezó, recortó ni giró, en lugar de llenar la memoria de tu Mac.

## 1.2
- Limpieza del escaneo (configuración de escaneo › Limpieza, y en cada ajuste de escaneo): recortar al papel, blanquear el fondo, quitar la trama de las imágenes impresas, restaurar los colores desteñidos. Limpiar… en una página la muestra en grande para probar cada opción, Mostrar tal como se escaneó para comparar, y Todas las páginas; Deshacer revierte una limpieza.
- Los PDF con texto buscable conservan el texto en todos los idiomas que lee tu Mac, incluidos ruso, árabe, chino, japonés y coreano, para que Vista previa y otras aplicaciones de PDF lo encuentren; elige el Idioma del texto de un escaneo o de un ajuste de escaneo.
- Las impresoras USB que imprimen sin controlador (IPP por USB) muestran sus propios niveles de tinta o tóner y su estado, leídos de la propia impresora; la tarjeta de estado dice de dónde vino su estado, y una impresora que no informa niveles lo dice.
- Notificaciones de trabajos (Configuración › Alertas, desactivadas hasta que las actives): cuando tu propio trabajo de impresión falla o deja de avanzar, una notificación nombra el documento y la impresora, con Abrir la cola y Pausar alertas. Los trabajos de otras personas nunca generan una.
- Historial de tinta y tóner: Inkvolt Print guarda una lectura al día en tu Mac y muestra un gráfico de los niveles del último año, cuántos días le quedan aproximadamente a cada cartucho y cuántas páginas imprimiste desde que lo pusiste. Las alertas de tinta baja también dicen cuántos días quedan. Exportar historial… lo guarda todo como un solo archivo de hoja de cálculo (una función de Inkvolt Pro, gratis por ahora).
- Vigilancia del firmware: cuando cambia el firmware de una impresora, su tarjeta de estado lo dice. Impresoras HP: Mantener mis cartuchos funcionando, en la pestaña Configuración, desactiva las actualizaciones automáticas del firmware, para que una actualización que bloquea los cartuchos que no son de HP no pueda instalarse sola.
- Los escáneres que solo envían PDF funcionan, y un escaneo guardado sin cambios se conserva exactamente como lo envió el escáner.
- Ayuda › Inkvolt Pro…: escribe una clave de Inkvolt Pro; Inkvolt PDF en este Mac también la encuentra.
- Inkvolt PDF en este Mac muestra el estado y el tóner de tus impresoras de aquí al imprimir, y avisa antes de imprimir en una que está apagada o atascada.
- Ayuda › Informar un problema…: los detalles que necesita un informe de error, con las direcciones, los números de serie y tus nombres ocultos, para copiarlos en una incidencia de GitHub. Grabar esta impresora guarda lo que responde la impresora que se muestra, solo leyendo y sin lo que la identifica, como un .zip para adjuntar. No se envía nada.
- Flota, arriba en la barra lateral (Ver › Flota): todas las impresoras en una página, primero las que tienen problemas, con la tinta o el tóner de cada una, el contador de páginas, el firmware y cuándo se leyó por última vez; una impresora que no responde muestra lo último que dijo. Exportar… guarda la lista como hoja de cálculo o JSON, y Resolver todo reanuda las impresoras en pausa y les permite volver a aceptar trabajos, preguntando antes de cada una (funciones de Inkvolt Pro, gratis por ahora). Desde Terminal, `Inkvolt Print status --all --json` enumera todas las impresoras para un script.
- Imprimir en lote (Archivo › Imprimir en lote…): agrega archivos PDF e imágenes, o una carpeta entera, ponlos en orden y mira cuántas hojas lleva cada uno antes de imprimir nada. Imprimir los envía a la impresora uno por uno, pregunta primero cuando un lote pasa de 100 hojas, y Detener se detiene entre un archivo y otro; un archivo que cambió o que necesita contraseña nunca se imprime por sorpresa. Guarda una lista para volver a imprimirla, imprime una carpeta a medida que llegan archivos a ella, guarda los resultados como hoja de cálculo e imprime una lista desde Terminal con `Inkvolt Print print --list` (funciones de Inkvolt Pro, gratis por ahora).
- Abrir en Inkvolt PDF, cuando está instalado en este Mac: un ajuste de escaneo puede abrir sus PDF allí, Abrir los escaneos en Inkvolt PDF, en Configuración › General, abre cada escaneo guardado, y la barra de guardado lo ofrece después de guardar un PDF.

Las versiones 1.0 y 1.1 (compilación 5, publicada el 2026-11-06) tenían sus notas solo en `listing.json`.
