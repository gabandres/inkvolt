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
