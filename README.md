# WaifuX · Wallhaven

Fork de [WaifuX de jipika](https://github.com/jipika/WaifuX) dedicado exclusivamente a fondos de pantalla estáticos de Wallhaven. [English](README.en.md) · [日本語](README.ja.md)

La rama `feat/wallhaven-static-only` está en desarrollo. No hay una versión estable publicada de este recorte. Los resultados de compilación y pruebas no sustituyen las comprobaciones visuales y de pantallas físicas.

## Funciones

- Búsqueda, etiquetas, categorías General/Anime/Personas, contenido, colores, resolución, proporción y orden de Wallhaven. Anime es una categoría de imágenes.
- Favoritos y originales descargados, carpetas, bloqueo, ordenación y cola con cancelación y reintento.
- Una imagen por pantalla o un fondo común, rotación aleatoria o secuencial por carpetas y pausa con batería.
- Vista previa con zoom, recorte estático por pantalla y relleno desenfocado de imágenes verticales. Los originales se conservan.
- Sincronización local o WebDAV de los registros y originales de Wallhaven.
- Castellano, inglés, chino simplificado y japonés.

La lectura de bibliotecas antiguas filtra los registros compatibles y conserva los documentos originales. El traslado de la biblioteca y la sincronización solo operan sobre archivos registrados; no eliminan series, vídeos ni objetos antiguos de otras funciones. Esta versión no reproduce ni descarga series y no incorpora otros proveedores de fondos.

## Compilar

Se requiere macOS 14.4 o posterior. Usa una versión de Xcode compatible con el SDK de las APIs SwiftUI utilizadas y XcodeGen. La validación local de esta rama utiliza Xcode 27.3; el diseño Liquid Glass se adapta según la versión de macOS.

```sh
git clone https://github.com/jesusjodar/WaifuX.git
cd WaifuX
git switch feat/wallhaven-static-only
xcodegen generate
python3 scripts/verify-project-configuration.py
xcodebuild -project WaifuX.xcodeproj -scheme WaifuX -configuration Debug \
  -derivedDataPath build/validation 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

Solo existen los targets `WaifuX` y `WaifuXHelper`. El helper conserva las preferencias compartidas, los servicios de biblioteca y la aplicación de imágenes estáticas. Una compilación sin firma no equivale a una instalación ejecutable validada.

## Comprobar

```sh
bash scripts/test-wallhaven-static-core.sh
bash scripts/test-wallhaven-download-queue.sh
bash scripts/test-wallhaven-cloud-files.sh
python3 scripts/verify-spanish-localization.py
python3 scripts/test-wallhaven-helper-integration.py \
  build/validation/Build/Products/Debug/WaifuXHelper.app/Contents/MacOS/WaifuXHelper
```

Para revisar el arranque normal de la interfaz sin registrar el servicio instalado:

```sh
python3 scripts/test-wallhaven-ui-preview.py build/validation/Build/Products/Debug/WaifuX.app --full-startup
```

La prueba utiliza un servicio XPC temporal con la comprobación real de identidad del ejecutable. Aísla preferencias, cachés, registros y llavero de prueba; omite el actualizador y el guardado de la geometría de ventanas, y bloquea las operaciones del escritorio. Cierra la ventana o interrumpe el lanzador para retirar el servicio temporal.

Las pruebas del helper usan carpetas y preferencias temporales, un servidor WebDAV de bucle local y salida de escritorio deshabilitada. No registran el servicio instalado ni cambian el fondo personal. La búsqueda en directo, las credenciales, los gestos, varias pantallas, Spaces, reposo y reconexión requieren validación adicional en la app.

## Empaquetar

`bash scripts/package.sh` genera una compilación universal Debug para uso local, audita el contenido y crea ZIP y DMG con firma ad hoc para uso local. Guarda cada ejecución en un directorio distinto dentro de `build/static-wallhaven`; no instala ni abre la app. `WAIFUX_SOURCE_APP` permite empaquetar un producto Debug ya compilado, que se copia antes de firmarlo. Los archivos identifican expresamente la configuración.

Para distribución pública se necesita una identidad Developer ID válida, el perfil de aprovisionamiento del helper, notarización y una clave Sparkle propia del fork. Al configurar `WAIFUX_SIGN_IDENTITY` y `WAIFUX_HELPER_PROFILE`, el empaquetado utiliza Release y verifica su identidad. El helper Release rechaza clientes sin identidad de equipo: una firma ad hoc no permite utilizarlo. La plantilla Homebrew requiere el hash de un ZIP real; no contiene acciones para registrar extensiones ni borrar datos. Los flujos de esta rama no publican releases automáticamente.

El feed del fork es `https://jesusjodar.github.io/WaifuX/appcast.xml`, inicialmente sin versiones. Las comprobaciones automáticas están desactivadas. `scripts/generate-appcast.py` exige configurar `SUPublicEDKey` y una firma Ed25519 antes de anunciar un archivo real. No reutilices las claves de otro proyecto.

## Contribuir y atribución

Consulta [CONTRIBUTING.md](CONTRIBUTING.md) y [LOCALIZATION.md](LOCALIZATION.md). Las contribuciones de este recorte se dirigen a `jesusjodar/WaifuX`; el PR de traducción del proyecto original es independiente.

Se conservan la autoría original y la [licencia](LICENSE). Las imágenes y el servicio Wallhaven mantienen sus propias condiciones; la licencia del código no concede derechos sobre las imágenes.
