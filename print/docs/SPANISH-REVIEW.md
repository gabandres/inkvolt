# Inkvolt Print in Spanish: wording review

For the owner, to review the wording quickly. The app's text is in `print/src/InkvoltPrint.App/Strings.es.resx` and `shared/InkvoltPrint.Core/CoreStrings.es.resx` (2,209 strings in all); change a value there, keep its `{0}`, `{1}` (`LocalizationTests` checks them). Shots of the screens: [`docs/ux-review/spanish/`](../../docs/ux-review/spanish/).

The voice is the Store listing's: plain, neutral Spanish for every market, informal *tú*, sentence case. Names of products and protocols, shortcuts (key names included) and whatever the printer itself sends stay as they are, so a demo printer's "Yellow ink is low" is correct.

## The most visible strings

### The window

| English | Español |
|---|---|
| Overview | Resumen |
| Print | Imprimir |
| Scan | Escanear |
| Copy | Copiar |
| Photos | Fotos |
| Printer settings | Configuración de la impresora |
| Fleet | Flota |
| Printers | Impresoras |
| Add a printer… | Agregar una impresora… |
| Settings | Configuración |
| Help and shortcuts | Ayuda y atajos |
| About Inkvolt Print | Acerca de Inkvolt Print |
| Print a PDF | Imprimir un PDF |
| Fix it… | Resolver… |
| Fix all… | Resolver todo… |
| Export… | Exportar… |

### Status and supplies

| English | Español |
|---|---|
| Ready | Listo |
| Sleeping | En reposo |
| Paused in Windows | En pausa en Windows |
| Offline | Sin conexión |
| Paper jam | Atasco de papel |
| Load paper | Carga papel |
| Door open | Puerta abierta |
| Toner low | Tóner bajo |
| Toner very low | Tóner muy bajo |
| Cancel all | Cancelar todo |
| About {0:N0} pages left | Quedan unas {0:N0} páginas |
| Replacement: {0} | Repuesto: {0} |
| Levels over the last year | Niveles del último año |
| OK | Aceptar |
| Black toner (a name the app writes) | Tóner negro |
| Black ink (a name the app writes) | Tinta negra |

### Scan

| English | Español |
|---|---|
| One-click scans | Escaneos con un clic |
| Manage presets… | Administrar ajustes… |
| All scan options | Todas las opciones de escaneo |
| Page size | Tamaño de página |
| Searchable text (OCR) | Texto buscable (OCR) |
| Text language | Idioma del texto |
| Skip blank pages | Omitir páginas en blanco |
| Straighten pages | Enderezar páginas |
| Several photos on the glass | Varias fotos en el cristal |
| Scan more pages | Escanear más páginas |
| Save as PDF | Guardar como PDF |
| Save as images | Guardar como imágenes |
| Document to PDF | Documento a PDF |
| Split into files at | Dividir en archivos en |

### Copy, Print, Photos

| English | Español |
|---|---|
| ID card | Documento de identidad |
| Copy ID card | Copiar identificación |
| Actual size | Tamaño real |
| Fit to paper | Ajustar al papel |
| Both sides | Doble cara |
| One PDF | Un PDF |
| Batch | En lote |
| Drop a PDF here | Suelta un PDF aquí |
| Choose a PDF… | Elegir un PDF… |
| Add files… | Agregar archivos… |
| Add a folder… | Agregar una carpeta… |
| All pages | Todas las páginas |
| Add photos… | Agregar fotos… |
| Fit (whole photo) | Ajustar (foto entera) |
| Plain paper | Papel normal |
| Borderless | Sin bordes |

### Fix it and alerts

| English | Español |
|---|---|
| Fix printing problems | Resolver problemas de impresión |
| Print Spooler service | Servicio Cola de impresión |
| Printer on the network | Impresora en la red |
| Printer answers | La impresora responde |
| What Inkvolt Print can fix | Lo que Inkvolt Print puede resolver |
| Check again | Volver a comprobar |
| Notification area and alerts | Área de notificación y alertas |
| Quiet hours | Horas de silencio |

### Dialogs

| English | Español |
|---|---|
| Inkvolt Print settings | Configuración de Inkvolt Print |
| Language | Idioma |
| Same as Windows | Igual que Windows |
| Takes effect the next time Inkvolt Print starts. | Se aplica la próxima vez que se inicie Inkvolt Print. |
| Use Windows' setting | Usar la configuración de Windows |
| Reset to defaults | Restablecer valores predeterminados |
| What's new | Novedades |
| Report a problem… | Informar un problema… |
| Keyboard shortcuts | Métodos abreviados de teclado |
| Plugged in, needs its driver | Conectada, le falta su controlador |

## Word choices to check

Each of these could reasonably go another way; the first word is what the app says now.

- **Flota** for Fleet, the page of every printer. Common in IT Spanish; "Todas las impresoras" is plainer but long.
- **Ajustes de escaneo** for scan presets, the listing's "Ajustes de escaneo de un clic". Settings are **Configuración**, so the two don't mix.
- **Resolver…** and **Resolver todo** for Fix it… and Fix all, also inside sentences ("el Resolver… de cada impresora").
- **Este PC**, as the listing says "tu PC". Windows' own File Explorer says "Este equipo".
- **Legal** for the paper size, not "Oficio": Oficio is a different size in several countries. **Carta** for Letter.
- **Cartera** for the wallet photo size.
- **Bien** for a supply or a check that is OK.
- **Documento de identidad** and **Copiar identificación** for ID card and its button.
- **Servicio Cola de impresión** for the Print Spooler service, as Windows calls it in Spanish.
- **Quitar la trama** for descreen, **código patch** and **hoja Patch T** for the separator sheets, **Marcadores** for file-name tokens, **Limpieza** for Clean up.
- **Incidencia** for a GitHub issue ("Details" stays, it is the label on GitHub's English form), **firewall** as it is.
- **Shift, Delete, Enter, Home** stay in English in shortcut text, as the brief asked for shortcuts. Windows in Spanish says Mayús, Supr, Entrar and Inicio; changing them is about 15 strings.
- **"{0}: queda poco"** and **"{0}: se agotó"** in alerts and the Fleet page, because a supply's name can be masculine or feminine ("Tóner negro", "Tinta negra") or the printer's own English.
- **Names of Windows' own screens**, quoted in the instructions (for example "Agregar una impresora por medio de una dirección TCP/IP o un nombre de host", "Agregar una impresora local o de red con configuración manual", "Estado SNMP habilitado"): written from memory on an English Windows, so please compare them with a Spanish Windows.

## What stays in English

- **What's New**: the dialog is translated, its text is `print/WHATS-NEW.md`, in English.
- **The command lines** (`inkvoltprint`, and `InkvoltPrint.exe print` and `status --all`): scripts read them.
- Logs, the Report a problem details, export file columns, file-type names in the registry and print job names sent to Windows.
- Whatever a printer sends: its name, its status messages, the supply names of IPP and SNMP printers.
- Scan presets made before the change keep the names and folders they were saved with. New installs in Spanish start with Spanish ones (`Documentos\Escaneos`).
