# Novedades de Inkvolt Print

The Spanish of `WHATS-NEW.md`: what the app shows under Novedades when its interface is in Spanish (embedded beside the English,
`ReleaseNotes.For`), and the Store's es release notes (`packaging/README.md`, "Upload"). The same headings in the same order and
one line for each English line, every version (`WhatsNewSpanishTests` checks it): a line added to `WHATS-NEW.md` needs its
Spanish here. The voice is `docs/SPANISH-REVIEW.md`'s (informal *tú*, the app's own words for its commands).

## Next
- Ambas caras en un alimentador que escanea una sola cara: marca Ambas caras: dar la vuelta a la pila (o la opción del ajuste), escanea los anversos, dale la vuelta a la pila cuando se te pida y escanea los reversos. Las páginas salen en orden; si la bandeja de tu escáner invierte la pila, Reversos en el otro orden lo corrige, y la revisión te avisa cuando los anversos y los reversos no coinciden.
- Las páginas que entran de lado o al revés se ponen al derecho solas cuando su texto muestra cuál es la parte de arriba (Poner las páginas al derecho, activado de forma predeterminada, también en cada ajuste). Las páginas de las que no está seguro quedan como llegaron, y Deshacer las vuelve a girar.
- PDF más pequeños: la nueva opción Archivo más pequeño (blanco y negro) de un ajuste guarda cada página en blanco y negro, a menudo en una décima parte del tamaño o menos. Los escaneos en blanco y negro también se guardan así.
- Compartir un escáner en la red ahora es gratis para siempre, ya no es parte de Inkvolt Pro.
- Lista para el nuevo controlador de impresora de Windows: Acerca de esta impresora dice qué controlador usa Windows para ella, si la impresora funciona con el controlador propio de Windows y su modo de impresión protegida, y Configurar con el controlador de Windows la vuelve a agregar así, junto a la anterior. Se avisa de un escáner que solo funciona con su controlador de Windows, porque no escaneará en el modo de impresión protegida.
- Doble cara en una impresora que imprime por un solo lado: Imprimir un PDF, En lote y Copiar ofrecen Imprimir a doble cara a mano. Se imprimen los anversos, luego la aplicación te muestra cómo volver a poner la pila para tu impresora (te pregunta hacia dónde salió la cara impresa) e imprime los reversos.
- Imprimir el portapapeles: en la pestaña Imprimir, Imprimir el portapapeles imprime el texto que copiaste (colocado en páginas, con las opciones de siempre), una imagen copiada a través de Fotos, o los archivos que copiaste en el Explorador de archivos.
- La limpieza puede quitar un color: las líneas de un formulario rojo, las notas de un bolígrafo azul o un sello se vuelven blancos, y lo impreso en negro se queda. Elige rojo, verde o azul, o haz clic en el color de la página. Quitar perforaciones rellena con el color del papel las marcas redondas de las perforaciones cerca de los bordes. Las dos funcionan en cada escaneo, en cada ajuste y en cada página.
- Escaneos recientes: Escaneos recientes… en la pestaña Escanear muestra tus últimos escaneos guardados de todos los escáneres, para abrirlos, mostrarlos en su carpeta, enviarlos de nuevo por correo o imprimirlos. La lista se queda en este PC.

## 1.7.0
- Imprime en una impresora de red que no está configurada en Windows: Imprimir un PDF, Copiar e Imprimir fotos ahora envían las páginas directamente a la impresora por la red, en su propio formato, sin controlador y sin administrador. Si Windows tiene una cola para ella, la cola sigue siendo la opción predeterminada e Imprimir también ofrece "Imprimir directamente en la impresora". Ves imprimirse cada página, y la tarjeta de la cola de impresión muestra los trabajos de la propia impresora.
- La impresión en lote, el "imprimir una copia" de un ajuste de escaneo y los avisos de trabajos también funcionan con esas impresoras: cada archivo de un lote va directamente a la impresora, uno tras otro, y un trabajo que la impresora detiene termina el lote ahí para que nada se imprima dos veces; los avisos de trabajos te dicen cuándo la impresora abandona tu trabajo o deja de avanzar. La línea de comandos también imprime en ellas: indica el nombre de la impresora o su dirección como ipp://….
- Copia con la propia impresora: una impresora HP que acepta pedidos de copia puede copiar por su cuenta cuando pulsas Copiar, con la configuración de su panel de control, y no necesita una cola de Windows. A través de este PC sigue siendo la opción para tus propias copias, la intercalación, las dos caras y la vista previa.
- Las copias a través del PC pueden poner 2 o 4 páginas en cada hoja, salir sin intercalar (todas las copias de la página 1 y luego las de la página 2) y esperar en una vista previa hasta que pulses Imprimir.
- Escanear desde el botón de la impresora: en una impresora HP que ofrece Escanear a computadora, actívalo en la pestaña Escanear y este PC aparece en el panel de la impresora; elígelo allí y pulsa Escanear, y el ajuste de escaneo que elegiste se ejecuta aquí mientras Inkvolt Print o su icono en el área de notificación esté abierto. Un escáner cuyo controlador de Windows informa de su botón hace lo mismo; una impresora sin ninguno de los dos lo dice.
- Inkvolt Pro (gratis por ahora): comparte un escáner en la red. Un escáner USB, o un multifunción que no puede escanear por la red, se puede usar desde una app de escaneo de iPhone o Android, la Captura de Imagen de una Mac u otro PC: activa Compartir este escáner en la red en su pestaña Escanear, o desde el icono en el área de notificación. Está desactivado hasta que lo actives, solo funciona en redes que Windows llama privadas y solo mientras Inkvolt Print está abierto, y la tarjeta muestra la huella digital del certificado para compararla.
- Los escáneres cuyo controlador de Windows solo envía PDF ahora escanean como cualquier otro: sus páginas llegan a la pestaña Escanear para la revisión, el reconocimiento de texto y los ajustes.
- Escáneres con un controlador de Windows más nuevo (WIA 2.0): la pestaña Escanear muestra cuánto falta para cada página, Detener detiene la página que se está escaneando, y el cristal y el alimentador ofrecen cada uno sus propias resoluciones.
- Un escáner cuyo único controlador es un antiguo controlador TWAIN de 32 bits ahora aparece con su nombre y dice por qué no se puede usar aquí y qué controlador instalar, en vez de no aparecer.
- El Blanquear de la limpieza ya no hace más difíciles de leer las páginas desvaídas una vez restaurados sus colores.
- Los consumibles muestran las páginas que quedan y cuántas páginas rinde un cartucho lleno en más impresoras: las impresoras HP más nuevas y las de otras marcas que cuentan su tóner en páginas. También se ven sus páginas impresas y las páginas desde que se puso cada cartucho.
- Acceso SNMP… con un usuario SNMPv3 (Inkvolt Pro) funciona con más impresoras: elige el protocolo que usa la impresora junto a cada frase de contraseña, SHA-256, SHA-1 o MD5 para la autenticación y AES-128, AES-192, AES-256 o DES para la privacidad.
- Una impresora cuya página web está en un puerto propio se puede agregar por esa dirección (por ejemplo http://192.168.1.20:8080), y una que anuncia su página en la red se lee allí por sí sola.
- El estado de la impresora muestra lo que dice su panel de control, cuando eso dice más que el estado.
- Las impresoras que Windows configuró mediante WSD ahora muestran el estado y los niveles de tóner o tinta de la propia impresora cuando responde por SNMP, como las impresoras en un puerto TCP/IP.
- Una impresora agregada, quitada o con otro nombre en Windows aparece en la lista de impresoras, desaparece o toma su nuevo nombre en un segundo más o menos, en vez de en la siguiente revisión.
- El escaneo en lote también divide en códigos QR: una hoja con un código QR o un código de barras que dice PATCHT (como los que imprime Paperless-ngx) empieza un archivo nuevo, igual que una hoja con código patch. La hoja separadora que Inkvolt Print guarda para ti ahora lleva uno junto a sus barras.
- Obtener el controlador ahora también encuentra los controladores de Canon, HP y Brother y los de PFU (escáneres fi y SP de Fujitsu y Ricoh), cada uno en el sitio del propio fabricante y firmado por él, como ya lo hacía con Epson.
- Novedades aparece en español cuando Inkvolt Print está en español.
- Ayuda › Abrir la carpeta del registro en la versión de Microsoft Store abre la carpeta donde de verdad se guarda su registro, que Windows guarda en la carpeta del paquete de la app. Obtener el controlador muestra la licencia de Brother, Canon y PFU antes de descargar su controlador, que aceptas con Aceptar y descargar.

## 1.6.0
- Acceso SNMP… ahora le pregunta a la impresora antes de guardar: dice qué parte rechazó la impresora, o que respondió otro dispositivo, y no guarda nada; cuando la impresora no responde, o el rechazo puede no venir de tu impresora, Guardar de todos modos lo guarda tal cual.
- Una impresora que rechaza su inicio de sesión SNMP ahora lo dice, con qué parte y un botón Acceso SNMP…, en vez de aparecer sin conexión, y su notificación también lo dice.

## 1.5.0
- Un escáner USB conectado sin controlador ahora aparece en la lista de impresoras y en la pestaña Escanear como "Conectado, le falta su controlador", en cuanto lo conectas.
- Obtener el controlador: para escáneres e impresoras Epson, Inkvolt Print encuentra el controlador de Epson para tu modelo y tu PC en el sitio web de Epson y muestra su nombre, versión y tamaño. Descargarlo de Epson abre esa descarga en tu navegador; ejecuta el instalador de Epson, e Inkvolt Print ve llegar el escáner y abre su pestaña Escanear. (Instalado con el instalador propio de Inkvolt en vez de la Store, descarga el controlador, comprueba que Epson lo firmó y lo instala cuando tú lo digas.)

## 1.4.0
- Los escáneres que solo tienen un controlador TWAIN (escáneres de película, escáneres planos antiguos y escáneres de documentos) ahora aparecen en la lista de impresoras, con su impresora o por su cuenta, y escanean en la pestaña Escanear como cualquier otro: cristal o alimentador, las dos caras, color, gris o blanco y negro, y la misma revisión, limpieza y ajustes. La ventana propia del controlador no se abre. Un escáner que también tiene un controlador de Windows aparece una sola vez.
- Escanea en blanco y negro: la opción Color de la pestaña Escanear ahora lo ofrece cuando el escáner lo permite.
- Los escáneres TWAIN siguen apareciendo cuando el servicio de escáneres de Windows no responde, y los escáneres que ya mostraba se quedan en la lista.
- Avisos de trabajos: un trabajo que falta en una mirada a la cola ya no vuelve a empezar su espera de atascado, un trabajo fallido se avisa a tiempo con la ventana cerrada, y un trabajo recién avisado no se vuelve a avisar tras reiniciar.
- La nota de la limpieza sobre el borde del papel cuenta solo las páginas en las que se buscó el borde y no se encontró, no una página que recortaste tú ni una que aún no se revisó.

## 1.3.0
- Una impresora USB para la que Windows no tiene controlador ahora aparece en la lista de impresoras como *Conectado, le falta su controlador*, con lo que hay que hacer paso a paso: la página de controladores de su fabricante (la de HP para una HP), las actualizaciones opcionales de Windows Update o agregarla en Windows. Lo dice cuando el modo de impresión protegida de Windows deja fuera los controladores de los fabricantes. Cuando ya hay un controlador pero Windows no creó una cola, *Configurarla* crea una. Algunas impresoras antiguas (láseres USB basadas en el equipo) solo funcionan con el controlador de su fabricante.
- Las impresoras USB (y otras configuradas en Windows) pueden mostrar sus niveles de tinta o tóner: a una impresora que Windows configuró con su propio controlador IPP, por USB o por la red, se le piden sus niveles y problemas igual que a una impresora Wi-Fi, y la página dice de dónde vienen. Con el controlador de un fabricante, se le pregunta luego al controlador ("De su controlador"), cuando puede decirlo. Una que no informa ninguno dice "Esta impresora no lo informa".
- Inkvolt Print habla español: sigue el idioma de Windows, o elígelo en Configuración › Idioma (Igual que Windows, English o Español). Se aplica la próxima vez que se abre la app.
- Imprimir un PDF funciona en cualquier pantalla: el botón Imprimir queda a la vista debajo de las opciones, que se desplazan cuando la ventana es baja. En pantallas pequeñas podía quedar cortado sin forma de llegar a él.
- En la pantalla pequeña o escalada de una laptop la ventana cabe: su barra de título con Minimizar y Cerrar quedaba por encima del borde superior de la pantalla.
- Windows 10: la ventana tiene un fondo sólido y se ven todos los iconos.
- Revisión del escaneo: una página que devuelves con Deshacer, la página que ocupa el lugar de una eliminada y una página que mueves ahora llegan a su sitio con suavidad. Nada se mueve mientras se escanea o se guarda, ni cuando los efectos de animación de Windows están desactivados.
- Ctrl+K llega al menú de cada impresora: escribe el nombre de una impresora y un comando ("recepción resolver") para ejecutarlo en esa impresora de inmediato, sin mostrarla primero.
- Las impresoras que solo responden por SNMP pueden tener su propia comunidad: escríbela en Acceso SNMP al agregar la impresora por su dirección, o cámbiala luego desde el menú de la impresora (Acceso SNMP…). Se guarda en el Administrador de credenciales de Windows y solo se usa para leer la impresora.
- Inkvolt Pro (gratis por ahora): SNMPv3. Para una impresora que solo responde por SNMPv3, escribe su nombre de usuario y sus dos frases de contraseña en vez de una comunidad. Cada petición va firmada y cifrada (SHA-256, AES-128), e Inkvolt Print dice si la impresora rechazó el nombre de usuario o una frase de contraseña.
- El mensaje largo de un problema de la impresora pasa a la línea siguiente en su tarjeta de estado; antes se cortaba en el borde de la tarjeta.

## 1.2.0
- Impresión en lote: Imprimir › En lote acepta muchos PDF e imágenes, o una carpeta. Cada archivo tiene sus propias copias, páginas, caras y papel, y ves las hojas que ocupa cada uno y en total antes de que se imprima nada. Van en orden, se muestra el resultado de cada uno, y un lote que se detiene dice dónde y sigue desde ahí sin imprimir nada dos veces.
- Un archivo que cambió o desapareció después del cálculo no se imprime, y un rango de páginas o un papel que un archivo o la impresora no tiene se indica en su línea, nunca se cambia sin avisar.
- Inkvolt Pro (gratis por ahora): guarda un lote como lista, conserva los resultados como hoja de cálculo, imprime una carpeta a medida que llegan archivos a ella, e imprime desde un script o una tarea programada con inkvoltprint print --list archivo --printer nombre.
- Limpia los escaneos: recorta al papel, blanquea el fondo y quita las motas, quita la trama de las imágenes impresas y restaura los colores desvaídos. Activa cada cosa para un escaneo o un ajuste, o por página en la revisión, y Deshacer lo devuelve.
- Los PDF con texto buscable ahora funcionan en cualquier idioma: griego, cirílico, árabe, hebreo, chino, japonés, coreano y más se pueden encontrar en el texto oculto. Si tienes varios idiomas de OCR instalados, elige uno en Idioma del texto.
- Flota: una página nueva, desde el botón de arriba de la lista de impresoras, muestra todas las impresoras a la vez con su estado, niveles de tinta o tóner, contador de páginas, firmware y cuándo se leyó por última vez, primero las que tienen problemas.
- Resolver… ahora también funciona en impresoras que solo conoce Windows (USB, compartidas desde otro PC): encuentra una cola en pausa, Usar impresora sin conexión y trabajos atascados, y los arregla después de preguntar. Reanudar una cola y desactivar Usar impresora sin conexión ahora preguntan primero en todas las impresoras, porque los trabajos en espera empiezan a imprimirse.
- Inkvolt Pro (gratis por ahora): Exportar… en la página Flota guarda la lista como hoja de cálculo o JSON, inkvoltprint status --all --json le da la misma lista a un script o a una tarea programada, y Resolver todo reanuda las colas en pausa y desactiva Usar impresora sin conexión en todas partes, preguntando por cada una.
- Avisos de trabajos: activa "Avisarme cuando uno de mis trabajos de impresión falle o se quede atascado" en Configuración, y el fallo de tu trabajo, o ningún avance durante 5 minutos en una impresora lista (15 si la impresora dice que está imprimiendo), te avisa, con el nombre del documento y Abrir la cola. Un trabajo atascado vuelve a avisarte solo si avanzó entretanto, tres veces como máximo. Desactivado salvo que lo actives. Los trabajos de otras personas nunca generan uno.
- Informar un problema puede grabar la impresora que se muestra: cada respuesta que Inkvolt Print lee de ella, solo lectura, sin números de serie, direcciones ni nombres, guardada como archivo .zip para que lo leas y lo adjuntes. No se envía nada.

## 1.1.0
- Historial de tinta y tóner: Inkvolt Print guarda una lectura al día en tu PC y muestra un gráfico de los niveles del último año, cuántos días le quedan más o menos a cada cartucho y cuántas páginas imprimiste desde que lo pusiste. Las alertas de tinta baja también dicen cuántos días quedan. Exportar historial… lo guarda todo en una hoja de cálculo (una función de Inkvolt Pro, gratis por ahora).
- Vigilancia del firmware: cuando cambia el firmware de una impresora, Inkvolt Print lo dice en su tarjeta de estado ("El firmware cambió de … a … el …") y, con las alertas activadas, una vez en una notificación.
- Impresoras HP: Mantener mis cartuchos funcionando, en Configuración de la impresora › Firmware, desactiva las actualizaciones automáticas del firmware con un clic, para que una actualización que bloquea los cartuchos que no son de HP no pueda instalarse sola, y comprueba que la impresora lo conservó.
- Pulsa Ctrl+K para encontrar cualquier comando escribiendo: mostrar otra impresora, ir a Escanear, ejecutar un ajuste de escaneo, resolver problemas de impresión, abrir Configuración… Arriba y abajo eligen, Entrar lo ejecuta.
- Con un tamaño de texto grande o una ventana pequeña, la lista de impresoras se pliega en un botón Impresoras arriba, como hace Configuración de Windows, para que la página de la impresora conserve su espacio. Púlsalo para abrir la lista sobre la página.
- Cambiar de pestaña o de impresora, y una línea de estado nueva, ahora aparecen con una breve transición en vez de cambiar de golpe. Nada se mueve cuando los efectos de animación de Windows están desactivados.
- Las alertas ahora son notificaciones de Windows de verdad: una por impresora, con los botones Abrir impresora y Pausar alertas, guardadas en el Centro de notificaciones. Una alerta más reciente de la misma impresora reemplaza la que todavía se ve.
- Versión de Microsoft Store: Iniciar con Windows se ofrece en Configuración › Área de notificación y alertas, directamente en el área de notificación; Aplicaciones de arranque del Administrador de tareas la muestra y puede desactivarla.
- Ayuda › Inkvolt Pro…: escribe una clave de licencia de Inkvolt Pro, mira a quién está licenciada o quítala. Una clave sirve para Inkvolt Print e Inkvolt PDF en este PC: escríbela en cualquiera de las dos apps y la otra la encuentra. Todo sigue gratis mientras las apps se lanzan; una licencia (19 dólares, un solo pago, sin cuenta, comprobada en tu PC y nunca enviada a ninguna parte) apoya el proyecto y te conserva las funciones Pro cuando empiecen a pedir una clave.
- Deshacer en la revisión del escaneo: una página eliminada vuelve, y también un giro, un recorte o un movimiento (el botón Deshacer, o Ctrl+Z). La línea de estado dice cómo después de eliminar una página.
- En la revisión del escaneo, Ctrl+R y Ctrl+L giran la página seleccionada y Ctrl+S la guarda como PDF. La Ayuda los muestra.
- Los escáneres que desde el alimentador solo envían PDF ahora escanean como los demás: las páginas aparecen para revisarlas, y girar, recortar, enderezar, omitir páginas en blanco, dividir en archivos, el reconocimiento de texto y los ajustes funcionan. Guardado como PDF sin cambios, el archivo es exactamente el PDF que envió el escáner.
- Inkvolt Print sigue el tamaño del texto de Windows (Configuración › Accesibilidad): todo se agranda con él. En tamaños grandes las pestañas pasan a otra línea en orden y los botones Imprimir un PDF y Escanear se colocan debajo del nombre de la impresora.
- Las preguntas ("¿Quitar esta impresora?", "¿Descartar las páginas?") muestran la pregunta como título y en la barra de título, con la explicación debajo; un mensaje que solo informa se cierra con Cerrar.
- Los títulos de la configuración de escaneo no quedan debajo de la barra de desplazamiento, ni el texto de Novedades.
- Los vínculos y los botones de página de la revisión del escaneo (girar, recortar, eliminar) son más fáciles de pulsar (al menos 24 px) y muestran un marco de foco cuando se llega a ellos con Tab.
- El cuadro de dirección de Agregar una impresora muestra un ejemplo hasta que escribes.
- Para quien ayuda a probar impresoras: inkvoltprint record <dirección> <carpeta> guarda todo lo que Inkvolt Print lee de una impresora, sin números de serie, direcciones ni nombres, para que las peculiaridades de tu impresora pasen a formar parte de las pruebas de Inkvolt Print. Solo lee; nada cambia en la impresora.

## 1.0.8
- Cuando Inkvolt Print ya guardó algunos de tus escaneos o envió algunas impresiones durante al menos dos días, te pregunta una sola vez si quieres calificarla en Microsoft Store, en la propia ventana de la Store. Nunca vuelve a preguntar, elijas lo que elijas.

## 1.0.7
- Agregar una impresora: busca en tu red las impresoras que no aparecen solas, devuelve las impresoras que quitaste, ayuda con las impresoras USB y acepta una dirección o la URL de una impresora.
- Los escaneos sin guardar vuelven después de un cierre inesperado en más casos (después de guardar, con un cuadro de diálogo abierto), y una impresora con escaneos sin guardar sigue en la lista.
- La revisión del escaneo cabe en ventanas pequeñas.
- Abrir varios archivos a la vez con Inkvolt Print los abre todos.
- Informar un problema oculta más datos personales y deja legibles los números de modelo y las versiones.

## 1.0.6
- El Resumen usa toda la ventana: sus tarjetas se ensanchan para llenarla.
- Agregar una impresora por su dirección: escribe la dirección de inmediato.

## 1.0.5
- Los escaneos sin guardar se conservan en el disco: después de un cierre inesperado, de cerrar la app a la fuerza o de un corte de luz vuelven en la pestaña Escanear.
- La configuración en un solo lugar: tema, dónde se guardan los escaneos, abrir los escaneos en Inkvolt PDF, ajustes, el área de notificación y las alertas, y Restablecer valores predeterminados.
- Ayuda (F1): atajos de teclado, consejos para encontrar una impresora, Informar un problema (copia los datos que necesita un informe, con las direcciones y los números de serie ocultos; la app no envía nada) y la carpeta del registro.
- La lista de impresoras dice por qué una impresora necesita atención ("Listo · Yellow ink is low").
- Copiar: tamaño real o ajustar al papel.
- Tema claro u oscuro, y la ventana se abre donde la dejaste.
- Sin ninguna impresora encontrada todavía, la ventana ya no muestra botones y pestañas de impresora que no tienen sobre qué actuar.

## 1.0.4
- Los niveles de tinta y tóner se siguen viendo cuando falla el informe de consumibles propio de una impresora: Inkvolt Print recurre al protocolo de impresión estándar.
- Cada actualización del estado le pregunta a la impresora una vez en vez de dos.
- Una impresora de red antigua que solo se conoce por SNMP y que pasa a otra dirección de red se comprueba por su número de serie antes de mostrarla allí.

## 1.0.3
- Las impresoras ya configuradas en Windows también aparecen, incluidas las USB, con el estado que informan Windows y el controlador de la impresora, la cola de impresión y la impresión de PDF y fotos.
- Las impresoras de red antiguas que no hablan IPP muestran su estado, alertas y niveles de tóner o tinta por SNMP.
- Los escáneres sin AirScan (USB, o con solo un controlador de Windows) escanean a través de Windows, con la misma revisión, PDF con texto buscable, ajustes y funciones de copia.
- Una cola a la que Windows no llega (el PC de una impresora compartida apagado, un servicio de impresión detenido) lo dice en vez de parecer quitada.
