# Novedades de Inkvolt PDF

The Spanish of `WHATS-NEW.md`, for the Store's es release notes (`packaging/README.md`, "Upload"); the app shows What's
New in English. Same headings and lines as `WHATS-NEW.md`, from the release after 1.11.1 on; the voice is
`docs/SPANISH-REVIEW.md`'s.

## Next
- Traducir con IA conserva más del aspecto de un párrafo: una palabra normal en un párrafo en negrita, una palabra en otro color o en otro tipo de letra (un nombre en Times entre Arial, código en letra de máquina de escribir), los subíndices y superíndices con su propio tamaño y altura, y un superíndice más largo que una llamada de nota. Un párrafo largo enviado por partes también conserva su aspecto, igual que un texto con su propio "<" o ">" (p < 0,05). Una línea con un superíndice o un subíndice recibe el espacio que necesita, para que no choque con la línea de arriba o de abajo. Las notas al pie que empiezan cada una con su llamada se traducen por separado, sin juntarse.
- Los títulos en la Times negrita de URW (NimbusRomNo9L-Medi, como en muchos artículos hechos con LaTeX) siguen en negrita al traducirlos o convertirlos a Word, y las letras matemáticas de LaTeX salen en cursiva.
- Reconocer texto lee más de 100 idiomas más con Tesseract, un reconocedor gratuito, para los que Windows no tiene (hindi, tailandés, hebreo, ucraniano, vietnamita y muchos más). Elige uno e Inkvolt PDF ofrece descargarlo (unos 30 MB la primera vez); no se descarga nada hasta que lo digas, y se queda en tu equipo.
- Páginas en dos idiomas: elige un segundo idioma en Reconocer texto. Cada línea se lee en el idioma que le corresponde, o los dos a la vez con Tesseract.
- En lote, Escanear, las exportaciones, Comparar archivos y Eliminar por patrón leen ahora los escaneos en el idioma que elegiste por última vez en Reconocer texto.
- Con Tesseract, una palabra de la que no estaba seguro aparece entre las palabras dudosas para revisar.
- La línea de comandos (`inkvoltpdf --batch`, `--watch`, `--fill`, `--help`) escrita en una terminal ya funciona: terminaba enseguida sin mostrar nada. Enviadas a un archivo o a otro programa, sus líneas ya no llevan un salto de línea de más tras cada una (una línea en blanco entre líneas en PowerShell, un carácter de más al final de cada una en un script).

## 1.15.0
- Mueve una nota, un resaltado, un subrayado o un tachado con la herramienta mano: arrastra una nota; haz clic en una marca de texto para seleccionarla y luego arrástrala (arrastrar en otro sitio sigue desplazando la página). Las flechas del teclado desplazan lo seleccionado. Sus respuestas se mueven con él.
- Cambia el color de una nota o de una marca de texto desde la barra que aparece al seleccionarla, o desde Color en el menú del panel Comentarios. Ctrl+Z deshace cualquiera de los dos cambios.
- Herramientas Polígono y Polilínea en el menú Dibujar (teclas V y Z): haz clic en cada esquina y luego doble clic o Enter para terminar; un clic en la primera esquina de un polígono lo cierra. Retroceso quita una esquina, Esc cancela. Color, grosor de línea y relleno como en las demás figuras.

## 1.14.0
- La comprobación de firmas a largo plazo es más estricta con archivos hechos para engañar: una marca de tiempo solo cuenta si su autoridad es de confianza, un certificado nunca queda como de confianza si el archivo tiene más datos de validación de los que lee una comprobación, y los datos guardados en un archivo no pueden ocultar un cambio posterior al documento (un adjunto, el formulario, el tamaño de una página).
- Las listas de revocación se leen con más cuidado: una que nombra un certificado con una fecha que no se puede leer lo cuenta como revocado, y una hecha para otra parte de los certificados de una autoridad no dice nada del tuyo.
- Firmar a largo plazo solo exige datos de validación completos para tu propia firma: el certificado de otro firmante que no nombra ninguna dirección utilizable ya no te lo impide.
- Los nombres y las direcciones de los certificados de un archivo se muestran en una sola línea, sin caracteres ocultos.

## 1.13.0
- Haz clic derecho en un PDF en el Explorador de archivos y elige "Convertir a Word con Inkvolt PDF": el archivo de Word se guarda junto a él (sin reemplazar otro archivo), sin abrir el PDF. Selecciona varios PDF para convertirlos todos a la vez. En Windows 11 está en "Mostrar más opciones"; aparece cuando Inkvolt PDF es la aplicación que abre tus PDF.
- Al convertir muchos PDF protegidos a la vez, se pregunta una sola vez si seguir, y cancelar una contraseña deja de pedirla para los demás.
- Editar un párrafo que forma parte de un dibujo reutilizado (como en muchos membretes y plantillas) lo escribe donde estaba, y el mismo texto mostrado dos veces se edita en cada copia por separado.

## 1.12.0
- Una barra de comandos conocida: Editar, Convertir, Comentar, Llenar y firmar, Organizar, Proteger y Escanear y OCR, donde los ponen Acrobat, Foxit y Nitro. Un clic hace lo principal de cada grupo; su flecha muestra lo demás, con una línea que dice qué hace cada cosa.
- Convertir › Word en un clic: el archivo de Word se guarda junto al PDF (sin reemplazar otro archivo) y se abre. Excel, PowerPoint, texto y HTML funcionan igual desde el menú Convertir. Mayús+clic, o Cambiar opciones… en el aviso, para elegir antes las páginas y otras opciones.
- Proteger solo pide una contraseña; Llenar y firmar coloca tu firma (o te ayuda a crearla); Comentar resalta el texto seleccionado; Escanear y OCR permite buscar en todas las páginas escaneadas.
- Los tipos de archivo de Convertir en sus colores (Word en azul, Excel en verde, PowerPoint en naranja) y Aplicar eliminaciones en rojo, para que se note el único paso que quita contenido para siempre; con contraste alto siguen los colores de Windows.
