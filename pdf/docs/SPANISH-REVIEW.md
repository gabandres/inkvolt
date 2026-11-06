# Inkvolt PDF in Spanish: wording review

For the owner, to review the wording quickly. The app's text is in `pdf/src/InkvoltPdf.App/Strings.es.resx` and Core's in
`pdf/src/InkvoltPdf.Core/PdfStrings.es.resx` (5,172 strings in all); change a value there, keep its `{0}`, `{1}` and its
access key `_` (`LocalizationTests` checks the placeholders). Shots of the screens: [`docs/ux-review/spanish-pdf/`](../../docs/ux-review/spanish-pdf/)
(`docs/ux-review/pdf-spanish.txt` renders them again).

The voice is Inkvolt Print's (`print/docs/SPANISH-REVIEW.md`, which you approved) and the Store listing's: plain, neutral
Spanish for every market, informal *tú*, sentence case (the English menus' Title Case goes). Names of products, formats and
keys (Del, Ctrl+Shift+S) stay as they are, and so does what a document says.

## The most visible strings

### The window and the command bar

| English | Español |
|---|---|
| File · Edit · View · Organize · Review · Help | Archivo · Edición · Ver · Organizar · Revisar · Ayuda |
| Hand · Fill & Sign · Comment · Draw · Organize | Mano · Llenar y firmar · Comentar · Dibujar · Organizar |
| Redact (bar button) | Eliminar información |
| Commands (Ctrl+K) | Comandos |
| Type a command, file, or page number | Escribe un comando, un archivo o un número de página |
| Open recent | Abrir recientes |
| Read, search, print and organize PDFs. | Lee, busca, imprime y organiza archivos PDF. |
| Tools · Recent · Clear list | Herramientas · Recientes · Borrar la lista |
| Edit text & images | Editar texto e imágenes |
| Reduce file size (start page) | Reducir tamaño |
| Recognize text (OCR) | Reconocer texto (OCR) |
| Batch | En lote |
| Create a PDF | Crear un PDF |
| Black out private details for good | Tapa y borra datos privados para siempre |

### File and Edit menus

| English | Español |
|---|---|
| Open… | Abrir… |
| Combine Files into PDF… | Combinar archivos en un PDF… |
| Compare Files… | Comparar archivos… |
| Batch: Actions on Many Files… | En lote: acciones en muchos archivos… |
| Save · Save As… | Guardar · Guardar como… |
| Print with Options… (booklet, pages per sheet, poster) | Imprimir con opciones… (folleto, páginas por hoja, póster) |
| Export to Word (.docx)… | Exportar a Word (.docx)… |
| Document Properties… | Propiedades del documento… |
| Search Folders… | Buscar en carpetas… |
| Protect with Password… | Proteger con contraseña… |
| Reduce File Size… | Reducir tamaño del archivo… |
| Save as PDF/A-2b (Archive)… | Guardar como PDF/A-2b (archivo)… |
| Flatten Comments and Fields… | Acoplar comentarios y campos… |
| Command Palette… | Paleta de comandos… |
| Settings… | Configuración… |

### Organize, Review, Fill & Sign, Draw

| English | Español |
|---|---|
| Organize Pages | Organizar páginas |
| Rotate Pages… · Delete Pages… · Extract Pages… | Girar páginas… · Eliminar páginas… · Extraer páginas… |
| Insert Pages from File… | Insertar páginas desde un archivo… |
| Split Document… · Crop Pages… | Dividir documento… · Recortar páginas… |
| Add Header & Footer… · Add Watermark… | Agregar encabezado y pie de página… · Agregar marca de agua… |
| Highlight Text · Underline Text · Strike Out Text | Resaltar texto · Subrayar texto · Tachar texto |
| Add Note · Stamp… | Agregar nota · Sello… |
| Add Signature or Initials… | Agregar firma o iniciales… |
| Sign Digitally… | Firmar digitalmente… |
| Prepare Form (Add and Edit Fields) | Preparar formulario (agregar y editar campos) |
| Pen · Highlighter Pen · Text Box · Callout | Pluma · Rotulador · Cuadro de texto · Llamada |

### Redaction, accessibility, what a file carries

| English | Español |
|---|---|
| Redact | Eliminar información confidencial |
| Mark Selected Text for Redaction | Marcar el texto seleccionado para eliminar |
| Apply Redactions… | Aplicar eliminaciones… |
| Redact by Pattern… | Eliminar por patrón… |
| Check Redaction… | Comprobar eliminación… |
| Accessibility Check… | Comprobación de accesibilidad… |
| Make Accessible (Tag)… | Hacer accesible (etiquetar)… |
| Reading Order and Alt Text | Orden de lectura y texto alternativo |
| Sanitize Document… | Limpiar documento… |
| What's in This PDF… | Qué hay en este PDF… |
| Recognize Text (OCR)… | Reconocer texto (OCR)… |
| Summarize with AI… | Resumir con IA… |
| Read Aloud | Leer en voz alta |

### Settings and dialogs

| English | Español |
|---|---|
| App theme · Use my Windows setting · Light · Dark | Tema de la aplicación · Usar mi configuración de Windows · Claro · Oscuro |
| Language · Same as Windows | Idioma · Igual que Windows |
| Takes effect the next time Inkvolt PDF starts. | Se aplica la próxima vez que se inicie Inkvolt PDF. |
| Keep recovery copies of unsaved changes | Guardar copias de recuperación de los cambios sin guardar |
| Dark pages (inverted colors for night reading) | Páginas oscuras (colores invertidos para leer de noche) |
| Author name on comments | Nombre del autor en los comentarios |
| AI assistant settings… | Configuración del asistente de IA… |
| Reset to defaults · Undo changes | Valores predeterminados · Deshacer cambios |
| Save changes to {0}? | ¿Guardar los cambios en {0}? |
| Save · Don't Save · Cancel | Guardar · No guardar · Cancelar |
| Keyboard Shortcuts · What's New · Report a Problem… | Métodos abreviados de teclado · Novedades · Informar un problema… |
| About Inkvolt PDF | Acerca de Inkvolt PDF |

## Word choices to check

Each of these could reasonably go another way; the first word is what the app says now.

- **Eliminar información confidencial** for Redact, from the listing ("elimina información confidencial de verdad"),
  never "redactar" (which means to write). The bar button says **Eliminar información**, the marks are **marcas de
  eliminación**, Apply Redactions is **Aplicar eliminaciones**, Check Redaction **Comprobar eliminación**. "Tachar" is
  Strike Out, so it isn't used for redaction.
- **Qué hay en este PDF** for What's in This PDF. The live listing says "What's in This PDF" in English; when this ships,
  the listing should say the same as the app (`pdf/packaging/README.md`).
- **Llenar y firmar** (the listing's) for Fill & Sign, and **llenar** a form throughout.
- **Acoplar** for Flatten (comments and fields into the page), as Acrobat in Spanish. "Aplanar" is the other common word.
- **Rotulador** for the Highlighter pen, so it isn't confused with **Marcadores** (bookmarks) or **Resaltar** (the text
  highlight).
- **Mano** for the Hand tool and **Comandos** for the palette button: short, as the bar is tight in Spanish (at 1400
  DIPs Draw goes into "…", where English keeps it; the rule is the same).
- **Ajuste predefinido** for a Batch preset (Print's scan presets are **ajustes de escaneo**). **Carpeta vigilada** for
  a watched folder.
- **Identificación digital** for digital ID, **marca de tiempo** for timestamp, **validación a largo plazo** for
  long-term validation, **punto de conexión** for an AI endpoint, **ppp** for dpi, **numeración Bates** as it is.
- **Edición** for the Edit menu (Windows' own word), **Revisar** for Review.
- **Informar un problema** for Report a problem, as Inkvolt Print.
- **Del**, **Enter**, **Shift**, **Page Up** stay in English in tips and shortcut text, as in Inkvolt Print (Windows in
  Spanish says Supr, Entrar, Mayús, Re Pág).
- **Text the app writes into a document now follows the interface language**: the default header/footer text ("Página
  <<page>> de <<pages>>"), the default watermark (CONFIDENCIAL), the notes a comparison or a translation adds, the
  comment summary. All are the person's own document text, editable before it is written. The built-in stamps
  (Approved, Draft…) and a visible signature's lines stay English, as a stamp's face is a fixed design.

## What stays in English

- **What's New**: the dialog is translated, its text is `pdf/WHATS-NEW.md`, in English.
- **The command line** (`--batch`, `--watch`, `--fill`) and the Office conversion helper's messages: scripts read them.
- Logs, dev scripts and the UIA audit, the Report a problem details, file formats and their columns (the redaction
  report's CSV, XFDF, FDF, form data CSV and JSON), the JavaScript form prelude's alerts, prompts sent to the AI.
- What a document says: its text, its comments, its attachments' names and descriptions.

## Inkvolt PDF for Mac

The Mac app's text is in `mac/InkvoltPdf/Resources`: `Localizable.xcstrings` (the app, 1,738 sentences) and
`PdfStrings.xcstrings` (what PdfCore shows: the menus, the accessibility check, the redaction check, What's in This PDF,
Batch, errors; 1,912); what it shows from Inkvolt Print (Scan, a printer's status) comes from Inkvolt Print for Mac's
`CoreStrings.xcstrings`. Open either in Xcode, or change a `"value"` in the JSON and keep its `{0}`, `{1}`
(`PdfStringsTests` checks them). Where Windows has the same English sentence, its Spanish above is used word for word
(about 2,800 of the 3,650); the rest is the Mac's own, in the same voice (*tú*, sentence case). What's New is in Spanish
on the Mac (`mac/InkvoltPdf/WHATS-NEW.es.md`, every version; the Sparkle notes get `xml:lang="es"` once a release has
`release-notes/<version>.es.md`). Inkvolt Print for Mac's What's New in Spanish is `mac/InkvoltPrint/WHATS-NEW.es.md`, and
the App Store's es-MX text is in `listing.json` (sent only once the listing has a Spanish localization).

### The menus: macOS's own names

The app builds its menu bar itself, so macOS doesn't translate it: the standard menus and items use the names of a Mac
in Latin American Spanish. Please compare them with a Mac in Spanish.

| English | Español |
|---|---|
| File · Edit · View · Go · Pages · Tools · Window · Help | Archivo · Edición · Visualización · Ir · Páginas · Herramientas · Ventana · Ayuda |
| About Inkvolt PDF · Settings… · Services | Acerca de Inkvolt PDF · Configuración… · Servicios |
| Hide Inkvolt PDF · Hide Others · Show All · Quit Inkvolt PDF | Ocultar Inkvolt PDF · Ocultar otros · Mostrar todo · Salir de Inkvolt PDF |
| New Window · Open Recent · Clear Menu · Revert to Saved | Nueva ventana · Abrir recientes · Borrar menú · Volver a la versión guardada |
| Page Setup… · Share… | Configurar página… · Compartir… |
| Undo · Redo · Cut · Copy · Paste · Select All | Deshacer · Rehacer · Cortar · Copiar · Pegar · Seleccionar todo |
| Zoom In · Zoom Out · Zoom to Width · Zoom to Page | Acercar · Alejar · Ajustar al ancho · Ajustar a la página |
| Show Sidebar · Show Toolbar · Customize Toolbar… · Enter Full Screen | Mostrar barra lateral · Mostrar barra de herramientas · Personalizar barra de herramientas… · Entrar en pantalla completa |
| Show Markup Toolbar · Hide Markup Toolbar | Mostrar barra de herramientas de marcación · Ocultar barra de herramientas de marcación |
| Minimize · Zoom · Bring All to Front | Minimizar · Zoom · Traer todo al frente |
| Annotate · Snapshot · Draw Signature… · Type Initials… | Anotar · Captura · Dibujar firma… · Escribir iniciales… |

### The Mac's own words

| English | Español |
|---|---|
| Same as macOS (Settings › Language) | Igual que macOS |
| Sidebar · Markup · Inspector · Share (toolbar) | Barra lateral · Marcación · Inspector · Compartir |
| Search every command (⇧⌘K) | Buscar cualquier comando (⇧⌘K) |
| Nothing you open leaves this Mac unless you send it. | Nada de lo que abres sale de este Mac a menos que tú lo envíes. |
| New here? Press ⇧⌘K and type what you want to do: … | ¿Eres nuevo? Presiona ⇧⌘K y escribe lo que quieres hacer: … |
| Show All Tools · Show Fewer · More Options | Mostrar todas las herramientas · Mostrar menos · Más opciones |
| “{0}” was changed by another program. | Otro programa cambió “{0}”. |
| Picture selected: drag to move it…, Delete removes it | Imagen seleccionada: arrástrala para moverla…, Suprimir la quita |
| Mark Search Matches · Clear Marks · Find and Mark | Marcar las coincidencias de la búsqueda · Borrar marcas · Buscar y marcar |
| Fix 1 Thing / Fix {0} Things | Resolver 1 cosa / Resolver {0} cosas |
| Sign “{0}” Digitally · No digital ID in the keychain | Firmar “{0}” digitalmente · No hay ninguna identificación digital en el llavero |
| Import a Digital ID File (.p12)… · trusted by this Mac | Importar un archivo de identificación digital (.p12)… · de confianza en este Mac |
| DRAFT (default watermark) · Faint / Solid | BORRADOR · Tenue / Sólida |
| Tab Earlier / Tab Later (Prepare Form) | Antes en el orden / Después en el orden |
| Signature pad: draw with the mouse or trackpad | Área de firma: dibuja con el mouse o el trackpad |
| Starting text recognition… The first time on this Mac, macOS loads it… | Iniciando el reconocimiento de texto… La primera vez en este Mac, macOS lo carga… |
| No voices are installed. Add one in System Settings › Accessibility › Spoken Content. | No hay voces instaladas. Agrega una en Configuración del Sistema › Accesibilidad › Contenido leído. |
| Bound on the left / Bound on the right (printing) | Encuadernado a la izquierda / Encuadernado a la derecha |
| Ask about this document… (Return sends) | Pregunta sobre este documento… (Retorno envía) |
| AI-generated, may be wrong | Generado por IA, puede estar equivocado |
| I understand: this text leaves this Mac for {0} | Entiendo: este texto sale de este Mac hacia {0} |
| Ollama (on this Mac) · Stays on this Mac | Ollama (en este Mac) · Se queda en este Mac |
| Tags the document on this Mac, from its layout: … | Etiqueta el documento en este Mac a partir de su diseño: … |
| The font {0} isn't embedded, and the Mac's matching font isn't installed. | La fuente {0} no está incrustada, y la fuente equivalente del Mac no está instalada. |
| The personal ID can't be made: {0} | No se puede crear la identificación personal: {0} |
| “{0}” is read-only. Save a copy under another name, or make it writable in its Get Info window. | “{0}” es de solo lectura. Guarda una copia con otro nombre, o permite escribir en él en su ventana Obtener información. |
| New PDFs' names: Scan, Images, Clipboard, Combined | Escaneo, Imágenes, Portapapeles, Combinado |

### Word choices to check

- **macOS's names**, written from memory of Latin American Spanish macOS, as Inkvolt Print for Mac's: **Configuración…**
  for Settings (Spain's macOS says Ajustes), **Configurar página…**, **Visualización** for View (the Windows app says Ver),
  **Configuración del Sistema › Privacidad y seguridad › Red local**, **Contenido leído**, **Obtener información**, **llavero**.
- **Marcación** for Markup (the toolbar button and the markup toolbar).
- **Redact**: the toolbar says **Eliminar información** (Windows' bar button), the Tools menu and the context menu the full
  **Eliminar información confidencial**; the bar's VoiceOver name is **Eliminación de información confidencial**.
- **Resaltador** names the highlighter's undo step (Windows' word) while the tool is **Rotulador**: say if it should be
  Rotulador everywhere.
- **Captura** for the Snapshot tool, but its notices say **instantánea**, as Windows has it.
- **Usar clave** for Enter Key (Inkvolt Pro), as Inkvolt Print for Mac, not Windows' Escribir clave.
- Keys written out as macOS names them: **Mayúsculas**, **Opción**, **Retorno**, **Suprimir** (Windows' tips keep Shift and
  Enter); ⌘ ⌥ ⇧ stay symbols.
- **Resolver** for Fix, **Detenida** for a stopped watched folder, **identificación personal** for a personal ID.
- **This PDF can't be read**: Windows has two orders; the Mac writes **Este PDF no se puede leer** everywhere, because the
  messages about comments, attachments and layers are made from it.
- Report a Problem says **incidencia** for a GitHub issue, as Inkvolt Print for Mac.

### What stays in English on the Mac

- The same as Windows (above), but What's New, which is in Spanish on the Mac.
- The self-test's report (`--self-test`, a developer aid; its `--strings` check is how the app checks the catalogs).
