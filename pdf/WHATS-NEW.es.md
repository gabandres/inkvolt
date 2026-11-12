# Novedades de Inkvolt PDF

The Spanish of `WHATS-NEW.md`, for the Store's es release notes (`packaging/README.md`, "Upload"); the app shows What's
New in English. Same headings and lines as `WHATS-NEW.md`, from the release after 1.11.1 on; the voice is
`docs/SPANISH-REVIEW.md`'s.

## Next

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
