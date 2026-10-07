# Chipa App

App interna de un emprendimiento de chipa para cargar stock y ventas. La usan varios amigos desde el celular. Hablar siempre en español rioplatense y sin tecnicismos: los usuarios no son programadores.

## Cómo está armada

- **Todo el frontend es `index.html`**: HTML + CSS + JS sin build ni dependencias locales. `supabase-js` v2 se carga desde jsDelivr; SheetJS (para "Descargar Excel") se carga recién al tocar el botón.
- **Base de datos: Supabase**, proyecto `chipa-app` (id `larilavpjbbbtldfeedw`, región São Paulo). La URL y la clave *publishable* están al principio del script de `index.html`; esa clave es pública por diseño.
- **`supabase.sql`** describe el esquema completo actual (tablas, vista, funciones, permisos). Si cambiás la base, actualizalo también.
- **Publicación: GitHub Pages** desde la rama `main` (raíz). Cada `git push` a `main` publica en https://clubdelacro1.github.io/Chipa-app/ en uno o dos minutos.

## Datos

- `productos`: stock. `unidad` es `'kg'` (chipas) o `'unidad'` (panes). `cantidad` y `precio` están en esa unidad.
- `ventas`: cada venta guarda nombre del producto, cantidad, unidad, total, pagado (debe = total − pagado), formato, cliente ("A quién") y vendedor (email de quien la cargó).
- `pagos`: cada cobro con su medio (`efectivo` / `transferencia`; `null` = ventas de antes de existir el medio). Se crea al vender (lo que pagó en el momento) y con `registrar_cobro` al cobrar deudas. Las "cajas" se calculan desde acá.
- `deudas`: vista con las ventas que todavía deben algo (lista "Por cobrar").
- `formatos`: las **presentaciones de cada producto** (`producto_id`): 1 kg, 1/2 kg, 12 unidades = 0,36 kg, etc. `kg` es lo que descuenta del stock en la unidad del producto; `precio` es fijo opcional (vacío = cantidad × precio del producto). Se editan desde la app, en la tarjeta de cada producto (pestaña Stock). En Ventas aparecen las del producto elegido más "Otro" (o "Unidades") para escribir la cantidad a mano.
- En Ventas el **precio es editable**; Pagó + Debe = Precio. Precio 0 = regalo (solo descuenta stock).
- `resumen`: vista con el valor del stock, total vendido, cobrado en efectivo / transferencia / sin dato y total por cobrar.
- Las operaciones que tocan stock o plata pasan por funciones en la base para que sean atómicas: `cargar_stock`, `registrar_venta` (descuenta, valida que alcance y registra el pago), `registrar_cobro` (cobra deuda, no deja cobrar de más), `anular_venta` (devuelve al stock; sus pagos se borran en cascada).
- Seguridad: RLS; solo usuarios logueados leen y escriben. Los usuarios se crean a mano en Supabase (Authentication → Users); el registro público está desactivado.

## Reglas al hacer cambios

- **Mantener compatible la base con la versión anterior de la página.** GitHub Pages deja la página guardada en los celulares unos 10 minutos, así que durante ese rato conviven la versión vieja y la nueva. Si cambiás la firma de una función de la base, agregá la nueva y dejá la vieja (o un envoltorio compatible); no la borres en el mismo cambio.
- No usar `confirm()` ni `alert()`: algunos navegadores de celular (los internos de WhatsApp/Instagram) los bloquean. Usar `confirmarEnBoton` y `mostrarError`.
- Las lecturas sin sesión devuelven listas vacías sin error; por eso `cargarDatos` verifica la sesión antes de leer, y los pedidos pasan por `conSesion`.
- Probar los cambios de la base dentro de una transacción con `rollback` antes de aplicarlos; hay datos reales.
- Antes de empezar a trabajar, `git pull` para traer los cambios de los demás.
