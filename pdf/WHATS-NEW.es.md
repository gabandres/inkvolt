# Novedades de Inkvolt PDF

The Spanish of `WHATS-NEW.md`: what the app shows under Novedades when its interface is in Spanish (`ReleaseNotes.For`),
and the Store's es release notes (`packaging/README.md`, "Upload"). The same headings in the same order and one line for
each English line, every version (`WhatsNewSpanishTests` checks it): a line added to `WHATS-NEW.md` needs its Spanish
here. The voice is `docs/SPANISH-REVIEW.md`'s (informal *tú*, the app's own words for its commands).

## Next
- Revisión ortográfica mientras escribes: el texto editado, las notas, los cuadros de texto, las llamadas y los campos de formulario subrayan en rojo las palabras mal escritas, en el idioma del documento. Haz clic con el botón derecho en una palabra para ver sugerencias, Omitir o Agregar al diccionario. Puedes desactivarla en Configuración.
- Buscar y reemplazar (Edición › Reemplazar…, Ctrl+H): cambia una palabra o frase en todo el documento, una coincidencia cada vez o todas a la vez (un solo paso de deshacer), con Mayúsculas y minúsculas y Solo palabras completas. Cada coincidencia aparece con su página y las palabras de alrededor. Un reemplazo que no se puede hacer como se pidió (un carácter que ninguna fuente tiene, un párrafo que chocaría con el texto de debajo) aparece en una lista al final.
- Intercalar páginas (Organizar): las hojas a doble cara escaneadas primero por un lado y luego por el otro vuelven a quedar en orden: anverso 1, reverso 1, anverso 2… Los reversos pueden ser páginas del mismo archivo o de otro PDF, en orden inverso (una pila a la que se le dio la vuelta) o no. Escanear los reversos (menú Archivo, y Escanear y OCR en la barra) escanea los reversos directamente en su lugar.
- Quitar páginas en blanco (Organizar) encuentra las páginas que son casi solo papel, te las muestra para que desmarques las que quieras conservar y las elimina en un solo paso que Deshacer revierte. Dividir en las páginas en blanco guarda las páginas que hay entre hojas separadoras en blanco como PDF separados. Las dos son también acciones de En lote.
- Marcadores a partir de los títulos (menú Ver, y un botón en el panel Marcadores): marcadores creados a partir de los títulos del documento, anidados por nivel y mostrados antes de crearlos. Reemplazan los marcadores o se agregan después.
- Cambiar el tamaño de las páginas (Organizar): pon las páginas en Carta, A4, Legal o un tamaño que escribas, con el contenido ajustado al papel o con su tamaño y márgenes agregados. Las páginas de distintos tamaños quedan de un solo tamaño, y los comentarios y los campos de formulario se mueven con el contenido.
- Reemplazar páginas (Organizar): cambia páginas por páginas de otro PDF. Los marcadores y los vínculos que llevaban a una página reemplazada llevan ahora a la página que ocupa su lugar.
- Etiquetas de página (Organizar): numera las páginas i, ii, iii o I, II, A, B, a, b, 1, 2, 3, con un prefijo (A-1) y un primer número, para cualquier intervalo: un prólogo en números romanos y el cuerpo desde 1 en un solo paso. El cuadro de página, las miniaturas e Ir a la página las muestran.
- Marcas de corrección (menú Revisar, Comentar en la barra y el clic derecho): Insertar texto pone un signo de intercalación azul donde deben ir palabras nuevas, con esas palabras como comentario; Reemplazar texto tacha las palabras seleccionadas y pone detrás un signo de intercalación con lo que va en su lugar. Son las marcas que hace Acrobat, así que Acrobat y otros visores las muestran igual, y Reemplazar texto es un solo comentario en el panel Comentarios, en Resumir comentarios y en los comentarios exportados.
- Sugerir qué eliminar (menú Revisar, Proteger en la barra; Inkvolt Pro): tu propio asistente de IA lee las páginas y sugiere nombres, empresas, direcciones y números de cuenta que eliminar, o lo que describas, y antes de enviar nada ves exactamente qué se envía y adónde. O guarda tu propia lista de nombres y términos, sin IA. Solo se conservan las palabras que de verdad están en la página; cada lugar donde aparecen entra en la misma lista que Eliminar por patrón para que lo aceptes u omitas, y el resultado se vuelve a leer y se comprueba.
- Guardar una respuesta de IA: el botón Guardar de una respuesta, o Revisar › Asistente de IA › Guardar la respuesta de IA y Guardar la conversación con la IA, la guarda como documento de Word o como PDF, con lo que preguntaste, sus referencias a páginas y el nombre del modelo, o la pone en el documento como nota en la página que cita. La conversación se queda con el documento mientras está abierto.

## 1.16.0
- Escanear: un ajuste predefinido con limpieza (creado en Inkvolt Print: recortar al papel, blanquear el fondo, quitar la trama de las imágenes impresas, restaurar colores desvaídos) ahora limpia cada página de la misma manera aquí.
- Traducir con IA conserva más del aspecto de un párrafo: una palabra normal en un párrafo en negrita, una palabra en otro color o en otro tipo de letra (un nombre en Times entre Arial, código en letra de máquina de escribir), los subíndices y superíndices con su propio tamaño y altura, y un superíndice más largo que una llamada de nota, por largo que sea (una lista de referencias elevada tras una palabra queda entera). Un párrafo largo enviado por partes también conserva su aspecto, igual que un texto con su propio "<" o ">" (p < 0,05). Una línea con un superíndice o un subíndice recibe el espacio que necesita, para que no choque con la línea de arriba o de abajo. Las notas al pie que empiezan cada una con su llamada se traducen por separado, sin juntarse.
- Traducir con IA mantiene subrayadas las palabras subrayadas: la línea dibujada debajo pasa a las palabras que las traducen, con su color y su grosor.
- Traducir con IA al árabe o al hebreo conserva las palabras en negrita, en cursiva, en color y subrayadas, los subíndices y los superíndices, cada uno en su sitio en la línea de derecha a izquierda.
- Una traducción al árabe o al hebreo abierta en el visor de PDF de Firefox (y en los demás visores hechos con pdf.js) conserva ahora los espacios entre sus palabras en árabe o en hebreo al copiarla o buscar en ella; antes salían todas juntas.
- Traducir con IA conserva hasta tres colores o fuentes distintos en un mismo párrafo (por ejemplo, una palabra en rojo y un nombre en Courier), cada uno como estaba; antes solo se conservaba el primero.
- Traducir con IA conserva más de lo que devuelve un modelo local pequeño: la negrita y la cursiva que marca a su manera, y una etiqueta o un nombre que pone entre corchetes angulares, que antes se perdían. Comprobado con un modelo local en español, francés, alemán, árabe y japonés.
- Los títulos en la Times negrita de URW (NimbusRomNo9L-Medi, como en muchos artículos hechos con LaTeX) siguen en negrita al traducirlos o convertirlos a Word, y las letras matemáticas de LaTeX salen en cursiva.
- Reconocer texto lee más de 100 idiomas más con Tesseract, un reconocedor gratuito, para los que Windows no tiene (hindi, tailandés, hebreo, ucraniano, vietnamita y muchos más). Elige uno e Inkvolt PDF ofrece descargarlo (unos 30 MB la primera vez); no se descarga nada hasta que lo digas, y se queda en tu equipo.
- Páginas en dos idiomas: elige un segundo idioma en Reconocer texto. Cada línea se lee en el idioma que le corresponde, o los dos a la vez con Tesseract.
- En lote, Escanear, las exportaciones, Comparar archivos y Eliminar por patrón leen ahora los escaneos en el idioma que elegiste por última vez en Reconocer texto.
- Con Tesseract, una palabra de la que no estaba seguro aparece entre las palabras dudosas para revisar.
- Reconocer texto endereza una página fotografiada en ángulo y aplana las líneas curvadas por el lomo de un libro antes de leerla, así que las fotos con el móvil y los libros abiertos se leen mucho mejor. Reemplaza los escaneos con las páginas limpias para conservarlas enderezadas. Las dos opciones vienen activadas y dejan como están las páginas que no las necesitan.
- Hacer el texto editable (menú Revisar, y Escanear y OCR en la barra) convierte el texto reconocido de una página escaneada en texto de verdad, con la fuente instalada más parecida a la del escaneo (también en cursiva, negrita o color), a su tamaño y en su sitio, para que puedas editar sus párrafos con Editar texto e imágenes. El escaneo se tapa detrás del texto con el color del propio papel, o queda a la vista si lo prefieres. Deshacer devuelve la página como estaba.
- La línea de comandos (`inkvoltpdf --batch`, `--watch`, `--fill`, `--help`) escrita en una terminal ya funciona: terminaba enseguida sin mostrar nada. Enviadas a un archivo o a otro programa, sus líneas ya no llevan un salto de línea de más tras cada una (una línea en blanco entre líneas en PowerShell, un carácter de más al final de cada una en un script), y sus líneas y errores enviados al mismo archivo (`> log.txt 2>&1`) se quedan todos ahí. Los errores enviados a un archivo propio (`2> errores.txt`) van a ese archivo.
- Eliminar información confidencial ya no deja ver el ancho de lo que quitaste. El texto que seguía a un recuadro negro se quedaba donde estaba, así que el hueco (y el propio recuadro) podía decir cuánto medían las palabras ocultas. Ahora cada línea con una eliminación se vuelve a componer: sus palabras conservan el orden, los espacios son iguales y el ancho del recuadro se redondea, así que la línea se ve igual sea lo que sea lo que había debajo.
- Comprobar eliminación también encuentra recuadros negros dibujados dentro de la imagen de una página (por programas que convierten las páginas en imágenes, o en un escaneo) con texto al lado que puede revelar el ancho oculto.
- La comprobación de accesibilidad compara los anchos que un PDF da a sus caracteres con los de la propia fuente en todo tipo de fuente incrustada, no solo TrueType: también las fuentes CFF y Type 1 (la mayoría de los PDF de InDesign, LaTeX y Acrobat).
- En lote, un archivo pequeño que al descomprimirse ocupa mucho más que su tamaño (uno de 200 KB que guarda 200 MB) se procesa solo, para que ya no les quite memoria a los archivos que se procesan a la vez.
- Exportar a PowerPoint y HTML conserva los vínculos del PDF: los vínculos a páginas web y a correos siguen abriéndose, y un vínculo a otra página lleva a esa diapositiva o a esa parte de la página. Solo quedan vinculadas las palabras que cubre el vínculo.
- Comparar archivos alinea una página escaneada a otro tamaño o girada un cuarto de vuelta (de lado o boca abajo) con la otra versión antes de mostrar lo que se ve distinto, así que la misma página ya no parece distinta por todas partes.
- Buscar en carpetas encuentra varias veces más rápido una frase de palabras comunes: una que tenía que revisar cada página de 10.000 archivos tardaba de 3 a 5 segundos y ahora tarda menos de un segundo.
- Reconocer texto y Comparar archivos ya no leen boca abajo una página escaneada por tener una imagen grande o un recuadro sombreado.
- Editar texto e imágenes reacomoda como un solo párrafo uno que mezcla tamaños o colores (una palabra más grande, una palabra en rojo, un subíndice): cada parte conserva su tamaño, su color y su altura, y un color queda exactamente como lo tenía el PDF.
- Los pares de letras nuevos que escribes en un texto con interletraje reciben el interletraje propio de la fuente ("To", "AV"), así que las líneas editadas quedan tan ajustadas como las de alrededor.
- Una imagen pequeña en la línea de un párrafo, entre sus palabras, ahora se mueve con sus palabras al editar el párrafo. En el editor aparece como ￼; borra la marca para quitar la imagen. Imagen… en la barra del editor agrega una nueva donde está el cursor.
- Recorta una imagen: selecciónala, elige Recortar imagen (o pulsa C) y arrastra sus controladores hacia dentro. Lo que recortas se quita del archivo, no solo se oculta, así que nadie puede recuperarlo del PDF; Deshacer quita el recorte mientras trabajas.
- Hacer accesible encuentra las filas que comparten una etiqueta en tablas dibujadas sin líneas (una región sobre sus países) y etiqueta esa celda como extendida sobre esas filas, para que un lector de pantalla la lea con cada una.
- Ayuda › Abrir la carpeta de registros en la versión de Microsoft Store abre la carpeta donde de verdad se guarda su registro, que Windows guarda en la carpeta del paquete de la app.
- Las novedades se muestran en español cuando Inkvolt PDF está en español.

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

## 1.11.1
- Algunos PDF que la 1.11.0 abría solo para ver (una página cuyo dibujo tiene muchos corchetes, como una imagen sin comprimir o referencias del tipo "[1]") se pueden volver a llenar y editar.
- Un archivo cuyo índice vuelve sobre sí mismo se abre reparado y se puede editar, en vez de abrirse solo para ver.
- Las casillas de seguro social, teléfono y código postal divididas en celdas muestran cada dígito en su celda (123-45-67 perdía los dos últimos), y un número pegado con sus guiones entra completo.
- Un archivo cuya comprobación tarda demasiado se puede llenar en cuanto termina, en vez de que la app se quede esperándola mientras escribes.

## 1.11.0
- Los formularios del gobierno protegidos que permiten llenarse (entre ellos los de USCIS y OPM) ahora se llenan sin pedir contraseña, como en Acrobat: el formulario guardado conserva su protección, y los comentarios también funcionan cuando el formulario los permite. Los demás cambios siguen pidiendo la contraseña de permisos.
- Las casillas de seguro social, teléfono y ZIP+4 aceptan todos los dígitos que escribes: los guiones aparecen al salir del campo, como en Acrobat, en vez de contar para la longitud del campo mientras escribes (escribir 123456789 en la casilla del SSN de un formulario 540 de California daba 123-45-67).
- Los botones de opción y otros campos cuyo formulario no incluye cada botón en su grupo funcionan como un solo grupo, con el nombre del propio grupo, como en Acrobat; antes aparecían como campos de más llamados "field1_p1" y no se desactivaban entre sí.
- Una lista o lista desplegable que cambias muestra la nueva opción también en cualquier otro visor; las casillas de algunos formularios seguían mostrando la anterior en los navegadores.
- Una casilla de verificación que marcas muestra su marca en todas partes, también en formularios que venían sin un aspecto para ella o con uno roto (formularios de LaTeX): antes seguía vacía en Vista Previa, en los teléfonos y al imprimir.
- Los totales y otros campos calculados se actualizan en más formularios: un cálculo que fija directamente el valor de su propio campo lo conserva, como en Acrobat, y funcionan las funciones auxiliares AFSimple y AFExtractNums que usan los formularios.
- Un campo colocado en varias páginas aparece en cada una de ellas, y un campo lleno cuyo formulario no lo vincula de vuelta a su casilla muestra su valor en cualquier visor.
- Comparar nombra las dos páginas del texto que pasó a otro par de páginas ("página 2 → 2" tras insertar una página antes), donde decía "en la página 2"; y una página de tamaño cero ya no se toma por un escaneo.
- Buscar en carpetas vuelve a encontrar una frase con una palabra de más de 48 letras y dígitos (un código, un hash, un compuesto alemán antes o después de otras palabras); la 1.10.0 no la encontraba.
- Los formularios dañados se vuelven a abrir y llenar, con sus comentarios y marcadores: un archivo que otro programa guardó sobre una copia anterior de sí mismo, o cuyo índice está roto o falta (las páginas se veían, pero no se podía llenar ningún campo y al escribir se elegían herramientas). Escribe, marca casillas, los totales se recalculan y el archivo guardado se abre bien en todas partes; si hubo que reparar el archivo, una barra lo dice, y las firmas hechas antes de la reparación no se muestran como comprobadas. Además, Tab sigue pasando al campo siguiente después de escribirse un valor, en vez de volver al primer campo de la página.
- En un PC lento u ocupado no se pierde nada de lo que escribes o haces clic en un formulario: un clic en el campo siguiente ya no espera tras "trabajando" mientras se escribe el último valor, y un valor que el formulario rechaza ya no se lleva consigo el siguiente, tampoco justo antes de Ctrl+S.
- Un PDF hecho para detener la app (páginas o listas anidadas sin fin) ya no la cierra: sus páginas se muestran, y dice que no se puede editar.

## 1.10.0
- Buscar en carpetas encuentra el final o la mitad de una palabra larga, un código, un hash o un compuesto alemán (de más de 48 letras y dígitos), como lo hace Buscar en un documento abierto; antes solo encontraba su comienzo. Las carpetas ya indexadas se vuelven a leer una vez, por sí solas, después de la actualización.
- Traducir con IA conserva en la traducción las palabras en negrita y en cursiva de un párrafo, los subíndices y los superíndices ("d_model", "2¹⁰"), dibujados con la negrita o la cursiva de la propia página cuando las tiene; cuando la respuesta del modelo mezcla las marcas, ese párrafo se escribe sin formato.
- Comparar ya no se queda colgado con un documento muy largo frente a uno corto (miles de páginas frente a unas pocas): termina en segundos, Cancelar y cerrar la ventana lo detienen al instante, y guardar su informe es igual de rápido.

## 1.9.0
- Traducir con IA permite que la etiqueta de una tabla que está sola en su fila (un encabezado sobre las filas de debajo) use las celdas vacías de al lado, para que una traducción más larga conserve su tamaño.
- Traducir con IA pasa un vínculo y su subrayado a las palabras del vínculo cuando la traducción las conserva (un número de documento, un nombre), y quita el vínculo cuyas palabras se tradujeron, así que ningún subrayado empieza ya a mitad de una palabra.
- Traducir con IA también traduce celda por celda las tablas y el texto puesto de lado en una página (una tabla horizontal en una página vertical), y la traducción se lee en el mismo sentido que el original.
- Un párrafo con marcas de verificación, flechas u otros símbolos en la fuente estándar ZapfDingbats, como los escribían programas y formularios antiguos, también se edita como un párrafo completo, y los símbolos siguen en ZapfDingbats.
- Los dibujos grandes (planos con decenas de miles de líneas) aparecen y se desplazan más rápido: cada plano se lee y se dibuja una vez en lugar de dos, y los dos planos siguientes se dibujan mientras miras uno.
- Traducir con IA mantiene las cifras de una fila de tabla en sus columnas cuando la etiqueta de la fila y sus cifras se dibujaron como un solo texto (como los dibujan muchos artículos e informes): solo se traduce la etiqueta, y las cifras se quedan donde estaban.
- Traducir con IA permite que el texto blanco sobre una franja oscura (una barra de encabezado) use el ancho de la franja, para que una traducción más larga conserve su tamaño en vez de encogerse al ancho de la palabra original.
- Traducir con IA mantiene entero un párrafo cuando una de sus líneas empieza con un paréntesis, un corchete o unas comillas dibujados aparte, como suelen dibujar "(" y "[" los artículos hechos con LaTeX: el párrafo ya no se corta ahí, su última línea ya no queda sola tras un guion, y el signo se traduce con su frase.
- Traducir con IA separa de la fila de debajo una etiqueta de tabla que termina en dos puntos ("Índices de ingresos:"), para que la propia etiqueta de esa fila se quede en su fila.
- Traducir con IA conserva más a menudo el tamaño de un encabezado corto de tabla: un encabezado centrado con espacio libre a un lado se desplaza hacia él en vez de encogerse, y los espacios de un encabezado que la tabla dibujó en una sola pieza con su vecino son tan anchos como los de la propia página.
- Traducir con IA escribe el texto de una columna en un solo tamaño: cuando un párrafo tiene que encogerse para caber, los demás de su columna se encogen con él (no más de una quinta parte), en vez de salir cada uno con un tamaño propio.
- Acoplar ya no dibuja en la página lo que la página nunca muestra: la nota emergente de un comentario, un comentario marcado como invisible o un widget de formulario que no pertenece a ningún campo.

## 1.8.0
- Una página hecha para tardar minutos en leerse (unos pocos kilobytes que se descomprimen en gigabytes) se abandona a los 10 segundos: dice que tardaba demasiado en leerse, y el resto del documento se sigue mostrando, buscando, imprimiendo y exportando. Lo mismo vale para una imagen así en una página, o en Reducir tamaño del archivo.
- La acción Eliminar por patrones de En lote devuelve su texto a las páginas con eliminaciones, como lo hace Aplicar eliminaciones, para que en un escaneo con eliminaciones se pueda seguir buscando y seleccionando.
- Editar texto e imágenes también edita como un párrafo completo el texto girado (una columna de lado, un título en ángulo): se reacomoda en su propia dirección, con el editor girado para coincidir.
- Un párrafo con una palabra en otra fuente (un nombre en Times entre Arial, una línea que empieza con una) ahora se edita como un párrafo completo, y esa palabra conserva su fuente.
- Con texto grande (el Tamaño del texto de Windows) en una ventana más pequeña, el menú Comentar se queda en la barra de comandos; Imprimir y Rehacer le ceden el sitio (Ctrl+P y Ctrl+Y, y los menús Archivo y Edición, los siguen teniendo).
- Con texto grande, las miniaturas de las páginas en Organizar crecen con él, para que los botones de girar y eliminar de una página quepan en su miniatura.
- Un párrafo con letras griegas o signos matemáticos en la fuente estándar Symbol, como los escribían los programas antiguos, también se edita como un párrafo completo, y siguen en Symbol.
- Hacer accesible etiqueta pieza por pieza el texto dentro de los dibujos que reutiliza una página (una página colocada como un solo dibujo, un membrete), para que cada encabezado y cada párrafo se lean por separado.
- En el panel Orden de lectura, elige qué es una pieza en Tipo: un encabezado y su nivel, un párrafo, una leyenda, una nota al pie, una fórmula o una imagen (una lista puede convertirse en una tabla de contenido). Aplicar cambios la etiqueta así.
- Hacer accesible etiqueta como una sola celda una celda de tabla que abarca varias filas, para que un lector de pantalla lea su encabezado con cada una de esas filas.
- Hacer accesible y Guardar como PDF/A-2a les dan sus letras a los textos en las fuentes de mapa de bits de los artículos antiguos de TeX cuando el archivo nombra la fuente de TeX, para que se puedan leer en voz alta, buscar y copiar.
- En lote, las carpetas vigiladas, la línea de comandos, Archivo › Escanear y las exportaciones a Word, Excel, PowerPoint, HTML y texto siguen la opción "Enderezar y limpiar las páginas primero" de Reconocer texto: si está desactivada, leen las páginas tal como se escanearon.

## 1.7.0
- Inkvolt PDF habla español: sigue el idioma de Windows, o elige en Configuración › Idioma (Igual que Windows, English o Español). Se aplica la próxima vez que se inicie la app. La paleta de comandos sigue encontrando los comandos por sus nombres en inglés.
- En la pantalla pequeña o escalada de una laptop, el tamaño de la ventana cuando no está maximizada cabe en la pantalla, así que Minimizar y Cerrar siguen a la vista.
- Al certificar un formulario, puedes bloquear todos sus campos, solo los que elijas, o todos menos esos. Un cambio posterior en un campo bloqueado aparece como no permitido al comprobar las firmas. Es parte de Inkvolt Pro.
- En lote puede agregar datos de validación a largo plazo a muchos archivos firmados a la vez, con una marca de tiempo del documento si quieres, desde la ventana o la línea de comandos. Primero ves cada dirección a la que consultará, y cada archivo dice qué pasó. Es parte de Inkvolt Pro. Una carpeta vigilada cuyo ajuste predefinido agrega datos a largo plazo lo dice al iniciarla, en vez de fallar con cada archivo: no puede conectarse a internet por su cuenta (el --watch de la línea de comandos sí puede, con --online).
- Los menús Llenar y firmar, Comentar, Puntero y Dibujar dicen en una línea debajo de cada herramienta lo que hace.
- Con texto grande (el Tamaño del texto de Windows), la barra de comandos conserva más botones en una ventana más pequeña, y sus menús también usan el texto más grande.
- Guardar un archivo grande mientras un archivo de Word, Excel o PowerPoint se convierte a PDF ya no falla.
- El reconocimiento de texto vuelve a leer, por separado, las líneas que el reconocedor de Windows se salta en una página, así que Reconocer texto y Eliminar por patrón encuentran palabras que se les escapaban.
- El reconocimiento de texto ya no pone boca abajo una página de números, así que los números de tarjeta de un escaneo se leen bien y Eliminar por patrón los encuentra.
- El reconocimiento de texto ahora lee "1111" (cuatro 1 seguidos), que el reconocedor de Windows nunca lee y que le hacía dejar fuera toda la línea, así que se encuentran números de tarjeta como 4111 1111 1111 1111. También se vuelve a leer una palabra que quedó fuera dentro de una línea.
- En lote, Archivo › Escanear y las exportaciones a Word, Excel, PowerPoint, HTML y texto marcan las palabras dudosas como lo hace Reconocer texto. Abre un archivo hecho con En lote o un escaneo y ahí está el botón Palabras dudosas para revisarlas; una exportación dice cuántas encontró.
- Si la respuesta de un servidor de IA no es una respuesta de chat, ves un mensaje claro en vez de un error.
- Un PDF con una parte que se descomprime en cientos de megabytes se rechaza con un mensaje en vez de agotar la memoria. La comprobación de eliminación dice cuándo no se pudo buscar en una parte así.
- Ese límite ahora se cumple también mientras se abre un archivo y para cada forma en que puede estar comprimida una parte, así que un archivo hecho para descomprimirse en gigabytes al abrirse recibe el mismo mensaje. Optimizar deja una parte así como está, y una página que la contiene conserva sus imágenes.

## 1.6.0
- Traducir con IA (Revisar › Asistente de IA): una copia traducida se abre en una pestaña nueva con el original al lado, y las dos se desplazan juntas. Va párrafo por párrafo a través de tu propia IA, sin límite de páginas, y primero ves lo que se enviará y adónde. Nada va a ningún otro sitio.
- Cada párrafo se queda en su recuadro: su texto se ajusta ahí, se encoge si hace falta y recibe un comentario si aun así no cabe. Las tablas van celda por celda, y las imágenes se quedan donde están.
- Una traducción larga muestra cuánto ha avanzado, y puedes detenerla y quedarte con lo que ya está hecho. Tu archivo original no cambia.
- Eliminar por patrón también busca en páginas escaneadas, mediante el reconocimiento de texto en tu equipo, y lista cada coincidencia con su página y las palabras de alrededor. Acéptalas u omítelas una por una o todas a la vez, con la página junto a la lista, antes de que se quite nada.
- El reconocimiento de texto puede saltarse palabras y líneas enteras, así que una página leída así nunca se da por limpia: se marca para que la revises, y se señalan en ella los lugares con tinta donde no se leyó nada.
- Después de eliminar, el resultado se vuelve a leer y a buscar, y lo que se quitó se busca en el resto del archivo. En un lote, un archivo al que le queda algo falla y no se guarda.
- Guarda tus propios conjuntos de patrones con un nombre en este PC, y aplica uno a una carpeta con la acción Eliminar por patrones de En lote; las contraseñas de los archivos protegidos se piden como siempre.
- Un informe de lo eliminado, como página y como CSV, lista por archivo la página, el patrón y un valor enmascarado de cada eliminación. Nunca contiene el valor en sí.

## 1.5.0
- Comparar archivos acepta archivos de Word, Excel y PowerPoint y escaneos además de PDF, en cualquiera de los dos lados. Las palabras de un escaneo se reconocen primero en tu equipo, y una diferencia que puede ser un error de lectura lo dice.
- Comparar lista los cambios de formato (fuente, tamaño, negrita, cursiva, color) y los párrafos movidos aparte de los cambios de texto, y deja fuera los encabezados y pies de página repetidos. Desmarca cualquier tipo para ocultarlo.
- Los escaneos se alinean antes de superponerlos, así que una página que entró un poco torcida ya no parece distinta por todas partes.
- La copia anotada ahora también marca los movimientos, el formato y las zonas que se ven distintas, como una imagen que se cambió por otra.
- Validación a largo plazo: Agregar información de verificación guarda en un archivo firmado la prueba de que cada certificado era válido, para que sus firmas se puedan seguir comprobando después de que venzan los certificados. También puede agregar una marca de tiempo del documento (PAdES B-LTA), y Firmar digitalmente puede hacerlo todo al firmar. Es parte de Inkvolt Pro.
- Antes de que nada de eso se conecte a internet, ves cada dirección que se contactará y lo que recibe. Las direcciones de tu equipo o de tu red local nunca se contactan, digan lo que digan los certificados de un archivo.
- Abrir un archivo firmado ya no se conecta a internet para nada, cuando antes comprobaba la revocación por su cuenta. Comprobar las firmas en línea lo hace cuando lo pides, y los detalles de una firma ahora dicen qué contiene el archivo para comprobarla más adelante.
- Las marcas de tiempo ahora van solo por https. Se sugiere el servidor gratuito de Sectigo, y puedes escribir otro. No se contacta nada a menos que agregues una marca de tiempo.
- Si una actualización posterior cambia el aspecto de un campo de formulario bloqueado, ahora aparece como un cambio que la firma no permite, no solo como un valor cambiado.
- Algo superpuesto a una página firmada en una actualización posterior, como un campo que dice ser una marca de tiempo o un comentario escrito dentro de la propia lista de la página, ahora aparece como un cambio; en un archivo certificado sin cambios permitidos, como uno que la certificación no permite.
- Buscar en carpetas (menú Edición, Ctrl+Alt+Shift+F): encuentra al instante una palabra en todos los PDF de una carpeta, con el texto alrededor de cada resultado, y abre el archivo justo ahí. Inkvolt PDF indexa la carpeta en segundo plano, en tu equipo, y se mantiene al día cuando cambian los archivos. Los archivos que no puede leer se omiten y se listan.

## 1.4.0
- Guardar como PDF/A ahora funciona con los formularios del IRS y con documentos con marcas de verificación de Llenar y firmar, que antes rechazaba. La lista de cambios dice qué perdió o ganó la copia: los derechos de uso de Reader del formulario, y marcas de verificación dibujadas con una forma un poco distinta.
- Las copias PDF/A pasan un validador independiente en más archivos: los metadatos propios de las imágenes y de las páginas ya no se quedan en la copia.
- Comprobación de accesibilidad: un archivo que no puede comprobar hasta el final (muy largo, o hecho para hacerla lenta) ahora dice "No se comprobó por completo" y qué quedó fuera, y nunca se da por aprobado; En lote lo cuenta como fallido. Algunas tablas de archivos guardados con Word ya no fallan por error.
- Hacer accesible ya no cierra la app con un archivo que tiene un formulario que se dibuja a sí mismo.
- Preparar formulario: editar un cuadro de lista ya no borra sus selecciones predeterminadas ni lo que se eligió en él.
- Buscar es mucho más rápido en documentos largos: unas tres veces más rápido en un PDF de 5.000 páginas o en un conjunto grande de planos. En una búsqueda larga, Inkvolt PDF trabaja con varios núcleos del procesador a la vez, y en los archivos con contraseña se busca como antes.
- Exportar a PowerPoint: una diapositiva por página, con texto que puedes editar en cuadros de texto, los encabezados como títulos de diapositiva, tablas, imágenes y formas sencillas.
- Exportar a HTML: una sola página web que se adapta a cualquier pantalla, con encabezados, listas y tablas de verdad, y las imágenes dentro con sus descripciones. No tiene scripts y no carga nada de ningún sitio.
- En lote también puede exportar a PowerPoint y HTML.
- Reconocer texto endereza y limpia cada página antes de leerla: páginas torcidas hasta 15°, de lado o boca abajo, motas y papel gris. Salen menos palabras mal, y puedes elegir cualquier idioma de reconocimiento de texto instalado en Windows.
- Las palabras que pueden haber salido mal se listan como palabras dudosas, cada una junto a cómo se ve en la página. Corrige una o déjala como se leyó; la búsqueda encuentra la palabra corregida (Revisar › Revisar palabras dudosas).
- Reconocer texto también puede reemplazar las páginas escaneadas con las limpias, derechas, en su orientación y sobre papel blanco. Está desactivado a menos que lo marques.

## 1.3.0
- Escanear ahora encuentra los escáneres USB y otros que tienen un controlador de Windows, junto a tus escáneres de red, y los escáneres TWAIN cuando su controlador TWAIN está instalado. Escanea desde el cristal o una pila en el alimentador, por las dos caras donde el escáner lo permita, en color, escala de grises o blanco y negro.
- Al escanear se pueden omitir las páginas en blanco, como los reversos vacíos cuando escaneas por las dos caras hojas impresas por una sola. Viene activado y dice cuántas omitió.
- Guarda tu configuración de escaneo como un ajuste predefinido (origen, color, resolución, tamaño de página, reconocimiento de texto, páginas en blanco) y elígelo la próxima vez; funciona con cualquier escáner, en la medida en que ese escáner lo permita.
- Inkvolt PDF sigue el Tamaño del texto de Windows (Configuración › Accesibilidad): los cuadros de diálogo, las pestañas de arriba, la barra de comandos, los paneles, la página de inicio y Organizar páginas se agrandan con él. Las páginas conservan su propio zoom.
- Un aviso con Deshacer desaparece al cerrar el documento al que se refería, para que no pueda deshacer algo en un archivo que ya no está abierto.
- Los avisos y la paleta de comandos entran deslizándose brevemente en vez de aparecer de golpe; no se mueven en absoluto cuando los efectos de animación de Windows están desactivados.
- Limpiar y Reducir tamaño del archivo dicen lo que quitan con palabras sencillas ("propiedades del documento", "restos de ediciones anteriores") en vez de "metadatos XMP" y "objetos sin usar".
- Los cuadros dicen qué va en ellos: el panel de búsqueda, Buscar, el filtro de comentarios y el de métodos abreviados muestran una sugerencia hasta que escribes.
- La paleta de comandos (Ctrl+K) dice cuándo no hay coincidencias y qué probar; sin ningún archivo abierto, dice que los comandos del documento aparecen cuando abres uno.
- Una barra de comandos más ordenada, con palabras y no solo iconos: Llenar y firmar, Comentar, Dibujar, Eliminar información y Organizar son botones con nombre, y cada uno abre sus herramientas (agregar texto, marca de verificación, firmar; resaltar, nota, imagen, vínculo, sello…), y las herramientas mano y selección comparten uno. Los nombres ahora se ven con los tamaños de ventana normales; girar, eliminar páginas, buscar y combinar están en el menú ….
- La configuración se aplica en cuanto la cambias, como en la Configuración de Windows: sin botón Guardar. Deshacer cambios deja todo como estaba al abrir Configuración, Valores predeterminados incluido.
- La barra de iconos (Páginas, Marcadores, Búsqueda, Comentarios…) está en el orden de Tab con un anillo de foco visible, y F6 llega a ella.
- Los cuadros de diálogo que solo informan se cierran con Cerrar, no con Aceptar; Combinar dice "Aún no hay archivos" con lo que hay que hacer; las pestañas del panel Accesibilidad ya no se parten en dos líneas; el texto de Novedades ya no choca con su barra de desplazamiento.
- Cada cuadro de los diálogos tiene un nombre que lee un lector de pantalla (su etiqueta), incluidos los márgenes de Recortar, los intervalos de páginas y Propiedades del documento.
- Hacer accesible (menú Revisar): etiqueta un PDF para lectores de pantalla en tu equipo, sin subir nada. Los encabezados, párrafos, listas, tablas, imágenes y vínculos se detectan a partir del diseño, en orden de lectura, y se omiten los encabezados y pies de página y los números de página; tú confirmas el título y el idioma. Un solo paso que puedes deshacer.
- Orden de lectura y texto alternativo (menú Revisar): ve el orden que sigue un lector de pantalla como recuadros numerados en la página, y arrastra o pulsa Alt+Up / Alt+Down para corregirlo. Escribe una descripción para cada imagen, marca las decorativas o deja que tu propio modelo de IA sugiera una (primero ves lo que se envía y adónde).
- Hacer accesible también encuentra leyendas, notas al pie, una tabla de contenido, ecuaciones, listas dentro de listas, y los encabezados en el lateral de una tabla o que abarcan varias columnas. Los números de un gráfico siguen siendo parte del gráfico en vez de convertirse en una tabla.
- Los artículos escritos en LaTeX ahora leen en voz alta sus fórmulas después de Hacer accesible: los paréntesis grandes, las sumas y las integrales reciben los caracteres que muestran, así que pasan la comprobación PDF/UA.
- En Orden de lectura y texto alternativo, mueve una pieza a la página anterior o a la siguiente (Alt+Page Up / Alt+Page Down), para un recuadro lateral que continúa la página anterior. Todo funciona con el teclado: Page Up / Page Down muestra las piezas de otra página, Enter va a la descripción de una imagen y Esc vuelve. El texto hablado de una ecuación se puede cambiar como el de una imagen.
- Guardar como PDF/A-2a (menú Archivo): una copia para archivar que conserva las etiquetas del documento, para los archivos institucionales que piden PDF accesibles. En lote también tiene Hacer accesible y PDF/A-2a.
- Archivos enormes: un PDF de 256 MB o más se abre en su sitio en vez de leerse primero en memoria, así que un conjunto de planos de 1 GB muestra su primera página en medio segundo más o menos y usa una fracción de la memoria. Mientras está abierto, otros programas no pueden guardar encima; en cuanto lo editas, Inkvolt PDF lo suelta.
- Las páginas grandes se dibujan con varios núcleos del procesador, y una página llena de dibujo muestra una vista previa rápida mientras te desplazas, que se afina un momento después.
- Buscar en un documento largo lo lee más rápido y sigue mostrando enseguida las primeras coincidencias. Buscar otra vez en el mismo documento se salta las páginas que no pueden coincidir; en un conjunto de planos, una segunda búsqueda es instantánea.
- Ayuda › Inkvolt Pro…: escribe una clave de licencia de Inkvolt Pro, mira a nombre de quién está o quítala. Todo en Inkvolt PDF sigue siendo gratis durante el lanzamiento, funciones Pro incluidas; una licencia ($19, un solo pago, sin cuenta, comprobada en tu equipo y nunca enviada a ningún sitio) apoya el proyecto y te conserva esas funciones cuando empiecen a pedir una clave.
- Un párrafo con una palabra en negrita o en cursiva (como los escriben Word y la mayoría de los programas) ahora se edita como un solo párrafo: la palabra conserva su aspecto, y el texto nuevo en negrita o en cursiva usa la fuente negrita o cursiva del propio PDF cuando la tiene.
- La lista de fuentes del editor de párrafos ahora tiene todas las fuentes instaladas en tu equipo, no solo las catorce habituales.
- Un párrafo reescrito conserva el interletraje que tenían sus letras, así que las líneas editadas se ven tan ajustadas como las que no tocaste. Una palabra dividida con guion a final de línea se queda como la escribiste ("respon-sable"); el guion opcional que añadió el salto de línea desaparece.
- Editar una sola línea de texto ahora dibuja los caracteres que su fuente no tiene con la fuente más parecida de tu equipo, como lo hace la edición de párrafos, y lo dice debajo del editor.
- Editar texto e imágenes ahora edita el texto dentro de dibujos reutilizados (XObjects de formulario: páginas estampadas o acopladas, y los bloques que crean algunos programas), como párrafos o línea por línea. Un dibujo que se muestra más de una vez, o en varias páginas, se copia para el lugar donde hiciste clic, así que los demás no cambian.

## 1.2.1
- Cuando hayas guardado algunos documentos con Inkvolt PDF durante al menos dos días, te pregunta una sola vez si quieres calificar la app en Microsoft Store, en la propia ventana de la Tienda. No vuelve a preguntar, elijas lo que elijas.

## 1.2.0
- Editar texto e imágenes: haz clic en un texto para editar todo su párrafo. Lo que escribes se reacomoda en el recuadro del párrafo con su alineación y su interlineado, y se te pregunta antes cuando chocaría con lo que sigue.
- Edición de párrafos: los caracteres que no tiene la copia de una fuente en el PDF (una fuente incrustada suele tener solo las letras que usó el documento) ahora se dibujan con la fuente más parecida de tu equipo, cuyo nombre aparece debajo del editor; el resto del párrafo se queda en su propia fuente.
- Edición de párrafos: da a parte de un párrafo otra fuente, tamaño, color, negrita o cursiva desde la barra que está sobre el editor. Si vuelves a editar el párrafo más tarde, ese aspecto sigue ahí.
- La edición de párrafos es más cuidadosa: los párrafos de derecha a izquierda y los que tienen dentro una llamada de nota o un símbolo se editan línea por línea, y los espacios dibujados aparte van con el texto al que pertenecían.
- Qué hay en este PDF (menú Revisar, también en Propiedades del documento y en Limpiar): un solo informe de todo lo que lleva un PDF además de sus páginas y de lo que hace al abrirse: scripts y lo que llaman, cada dirección web, archivo y programa al que puede llegar (marcados cuando no hace falta ningún clic), archivos adjuntos, autores y otros metadatos, firmas, versiones anteriores y lo que todavía muestran, capas y texto ocultos, valores de formulario. Guárdalo como página web o JSON. No se contacta nada de lo que hay en el archivo. También es una acción de En lote.

## 1.1.0
- Búsqueda de actualizaciones: cuando hay una versión nueva lista en Microsoft Store, aparece un botón Actualizar en la parte superior de la ventana (Ayuda › Buscar actualizaciones… lo comprueba en ese momento). Puedes desactivarlo en Configuración.
- Comprobación de accesibilidad (Revisar › Comprobación de accesibilidad…): comprueba en tu equipo un PDF con PDF/UA, el estándar de los PDF que pueden usar las personas con lectores de pantalla. Cada problema dice qué está mal, dónde (haz clic en él para verlo en la página) y cómo corregirlo; una lista de comprobación cubre lo que solo una persona puede juzgar, como el orden de lectura y si las descripciones de las imágenes tienen sentido. Guarda el informe como página web. También es una acción de En lote, con un informe junto a cada archivo.
- Exportar e importar comentarios (menú Revisar): exporta todos los comentarios como XFDF o FDF para Acrobat y otras apps de PDF, o como CSV para una hoja de cálculo, con respuestas, colores, autores, fechas y el aspecto de sellos y dibujos; impórtalos en otra copia sin duplicar los que ya están. Resumir comentarios crea un PDF con cada página junto a sus comentarios, numerados y conectados.
- Exportar e importar datos de formulario (Edición › Formularios): exporta los valores de un formulario como XFDF, FDF, CSV o JSON y llena un formulario desde cualquiera de ellos. Llenar formularios desde CSV llena una copia del formulario por cada fila de una hoja de cálculo y lista las filas que no pudo llenar y por qué. También en En lote, y desde una terminal: inkvoltpdf --fill.
- Ajustes predefinidos de lote: guarda la lista de acciones de En lote con un nombre y elígela la próxima vez; exporta un ajuste predefinido para compartirlo o importa el de otra persona (un archivo JSON sencillo). Nueva acción de En lote: Guardar como PDF/A.
- Carpetas vigiladas (En lote › Carpetas vigiladas…): suelta archivos PDF o imágenes en una carpeta e Inkvolt PDF ejecuta un ajuste predefinido en cada uno en cuanto termina de copiarse, luego mueve el original a "done" o "failed" y anota una línea por él.
- Línea de comandos: inkvoltpdf --batch ejecuta un ajuste predefinido en archivos o carpetas sin abrir ninguna ventana, e inkvoltpdf --watch vigila una carpeta desde una terminal o una tarea programada (inkvoltpdf --help).
- Comprobación de eliminación: después de aplicar eliminaciones, Inkvolt PDF comprueba que no quede nada de lo que eliminaste en ninguna parte del archivo (otras páginas, comentarios, campos de formulario, marcadores, propiedades, archivos adjuntos, capas ocultas, versiones anteriores) y ofrece corregir lo que encuentre. Revisar › Comprobar eliminación… revisa cualquier PDF en busca de texto que siga bajo recuadros negros o resaltados, marcas de eliminación sin aplicar y más. También es una acción de En lote.
- Eliminar por patrón (menú Revisar): busca y marca números de seguro social, de teléfono y de tarjeta, direcciones de correo, fechas, números de cuenta bancaria (IBAN), direcciones IP, tus propias palabras o tu propio patrón, en todas las páginas o en algunas; revisa las marcas y luego aplícalas. También es una acción de En lote para muchos archivos a la vez.

## 1.0.8
- Más estable: algunos PDF hechos a propósito podían colgar o cerrar Inkvolt PDF (al eliminar páginas, reducir el tamaño, limpiar, eliminar información o llenar un formulario); ya no lo hacen.
- Al cerrar nunca se pierden los cambios hechos mientras pregunta por otro documento, y las copias de recuperación se conservan cuando falla una restauración o una escritura.
- Quitar protección funciona con archivos que solo tienen restricciones (sin contraseña de apertura).

## 1.0.7
- Herramientas en la página de inicio: Llenar y firmar, Editar, Exportar a Word, Combinar, Comparar, Reducir tamaño, Proteger, Eliminar información, OCR, Organizar, En lote y Crear un PDF, con un clic cada una (elige un PDF y se abre directamente en la herramienta).
- Organizar páginas tiene una barra con las acciones de página: girar, eliminar, duplicar, extraer, mover, insertar, recortar.

## 1.0.6
- Copias de recuperación: si Inkvolt PDF se cierra inesperadamente (un error, un corte de luz), al iniciarse de nuevo te ofrece recuperar los cambios sin guardar.
- Pestañas: haz clic derecho en una pestaña para Cerrar otras, Cerrar las pestañas de la derecha, Copiar ruta, Mostrar en la carpeta y Volver a abrir la pestaña cerrada; las pestañas con el mismo nombre muestran qué archivo es cada una.
- Configuración › Valores predeterminados.
- Ayuda › Novedades, y Ayuda › Informar un problema: copia los datos que necesita un informe, con las rutas de archivo y tus nombres enmascarados, para pegarlos en un issue de GitHub. La app no envía nada.
## 1.0.5
- Edición más estable: cada cambio de página, edición de formulario y firma pasa por un mismo camino probado que mantiene protegido un archivo protegido y las firmas de un archivo firmado, con el mismo historial de deshacer.
- Exportar a Word, Excel y texto usa un mismo camino probado, igual para archivos sueltos que para En lote.

## 1.0.3
- Edita texto e imágenes directamente en la página.
- Preparar formulario: crea campos de texto, casillas de verificación, botones de opción, listas, campos de firma y botones, o detecta automáticamente los campos de una página.
- Compara dos versiones de un PDF, en texto y visualmente.
- Exporta a Word, Excel o texto sin formato, con reconocimiento de texto para las páginas escaneadas. Los formularios conservan su diseño en Word: líneas para llenar, etiquetas y casillas donde estaban.
- Crea PDF a partir de archivos de Office (con tu Microsoft Office instalado) y de páginas web.
- Guardar como PDF/A-2b para archivar.
- Mide distancias, perímetros y áreas, con una escala de dibujo o una calibración.
- En lote: ejecuta las mismas acciones en muchos archivos a la vez.
- Vista dividida: dos lugares del mismo documento, uno al lado del otro.
- Limpiar documento: quita datos ocultos como metadatos, scripts, capas ocultas y archivos adjuntos.
- Encabezados y pies de página (con numeración Bates), marcas de agua, sellos, imágenes y vínculos.
- Vista previa de impresión en el cuadro de diálogo de impresión de Windows, con el ajuste de página (tamaño real o ajustar al papel) ahí mismo.
- Imprimir con opciones: páginas por hoja, folleto y póster.
- Asistente de IA opcional, con el tuyo propio (desactivado de forma predeterminada): resume, pregunta sobre un documento o explica un pasaje con Ollama, LM Studio o un servicio que elijas. Las respuestas las genera la IA y pueden estar equivocadas. Ves exactamente qué se envía, y adónde, antes de que salga nada.
- Los formularios llenos se ven igual en cualquier visor, iconos nuevos y muchas correcciones.
- Corregido: abrir archivos fallaba en equipos sin el runtime de Visual C++.
