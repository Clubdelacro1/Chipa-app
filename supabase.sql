-- Chipa App: estructura de la base de datos (estado actual).
-- Sirve para recrear la base en un proyecto nuevo: Supabase > SQL Editor > New query > Run.

-- ---------- Tablas ----------
-- Stock: cada producto se mide en kg (chipa) o en unidades (panes)
create table productos (
  id       uuid primary key default gen_random_uuid(),
  nombre   text not null check (length(trim(nombre)) > 0),
  cantidad numeric(10,3) not null default 0 check (cantidad >= 0),  -- kg o unidades
  precio   numeric(12,2) not null check (precio >= 0),              -- por kg o por unidad
  creado   timestamptz not null default now(),
  unidad   text not null default 'kg' check (unidad in ('kg', 'unidad'))
);
-- No se puede repetir un producto con el mismo nombre (sin importar mayúsculas)
create unique index productos_nombre_unico on productos (lower(nombre));

create table ventas (
  id          uuid primary key default gen_random_uuid(),
  fecha       timestamptz not null default now(),
  producto_id uuid references productos(id) on delete set null,
  nombre      text not null,
  cantidad    numeric(10,3) not null check (cantidad > 0),  -- kg o unidades descontadas
  precio_unit numeric(12,2),                                -- precio efectivo por kg
  total       numeric(14,2) not null constraint ventas_total_positivo check (total >= 0),
  pagado      numeric(14,2) not null default 0 check (pagado >= 0),  -- debe = total - pagado
  formato     text,                                         -- "1 kg", "1/2 kg x3", "Otro"...
  cliente     text,                                         -- a quién se le vendió
  vendedor    text default (auth.jwt() ->> 'email'),
  unidad      text not null default 'kg' check (unidad in ('kg', 'unidad'))
);
create index ventas_fecha on ventas (fecha desc);

-- Cada cobro (al vender o después) con su medio de pago: así se sabe en qué caja entró
create table pagos (
  id       uuid primary key default gen_random_uuid(),
  venta_id uuid not null references ventas(id) on delete cascade,
  fecha    timestamptz not null default now(),
  monto    numeric(14,2) not null check (monto > 0),
  medio    text check (medio in ('efectivo', 'transferencia')),   -- null = ventas anteriores, sin dato
  cobrador text default (auth.jwt() ->> 'email')
);
create index pagos_venta on pagos (venta_id);

-- Presentaciones de cada producto (botones de la pestaña Ventas), editables desde la app.
-- kg = cantidad que descuenta del stock, en la unidad del producto (kg o unidades).
create table formatos (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null check (length(trim(nombre)) > 0),
  kg          numeric(10,3) check (kg > 0),        -- null = falta cargar
  precio      numeric(12,2) check (precio >= 0),   -- precio fijo (null = según precio del producto)
  orden       integer not null default 0,
  producto_id uuid references productos(id) on delete cascade
);
create unique index formatos_producto_nombre on formatos (producto_id, lower(nombre));

-- Totales para mostrar arriba en la app
create view resumen with (security_invoker = true) as
select
  (select coalesce(sum(cantidad * precio), 0) from productos)                  as total_stock,
  (select coalesce(sum(total), 0) from ventas)                                  as total_ventas,
  (select coalesce(sum(monto), 0) from pagos where medio = 'efectivo')          as total_efectivo,
  (select coalesce(sum(monto), 0) from pagos where medio = 'transferencia')     as total_transferencia,
  (select coalesce(sum(monto), 0) from pagos where medio is null)               as total_sin_medio,
  (select coalesce(sum(total - pagado), 0) from ventas)                         as total_debe;

-- Ventas con deuda (para la lista "Por cobrar")
create view deudas with (security_invoker = true) as
select id, fecha, cliente, nombre, formato, cantidad, unidad, total, pagado, total - pagado as debe, vendedor
from ventas
where total > pagado;

-- ---------- Seguridad: solo usuarios logueados ----------
alter table productos enable row level security;
alter table ventas    enable row level security;
alter table formatos  enable row level security;
alter table pagos     enable row level security;
create policy "usuarios logueados" on pagos
  for all to authenticated using (true) with check (true);

create policy "usuarios logueados" on productos
  for all to authenticated using (true) with check (true);
create policy "usuarios logueados" on ventas
  for all to authenticated using (true) with check (true);
create policy "usuarios logueados" on formatos
  for all to authenticated using (true) with check (true);

-- ---------- Operaciones ----------
-- Cargar stock: si el producto ya existe suma la cantidad y actualiza el precio
-- (la unidad solo se usa al crear el producto)
create function cargar_stock(p_nombre text, p_cantidad numeric, p_precio numeric, p_unidad text default 'kg')
returns void language plpgsql set search_path = public as $$
begin
  if p_unidad = 'unidad' and p_cantidad <> trunc(p_cantidad) then
    raise exception 'Las unidades tienen que ser un número entero.';
  end if;
  insert into productos (nombre, cantidad, precio, unidad)
  values (trim(p_nombre), p_cantidad, p_precio, p_unidad)
  on conflict ((lower(nombre))) do update
    set cantidad = productos.cantidad + excluded.cantidad,
        precio   = excluded.precio;
end $$;

-- Compatibilidad con versiones anteriores de la página (que mandan p_kg en vez de p_cantidad)
create function cargar_stock(p_nombre text, p_kg numeric, p_precio numeric)
returns void language sql set search_path = public as $$
  select cargar_stock(p_nombre => p_nombre, p_cantidad => p_kg, p_precio => p_precio, p_unidad => 'kg');
$$;
revoke execute on function cargar_stock(text, numeric, numeric) from public, anon;
grant  execute on function cargar_stock(text, numeric, numeric) to authenticated;

-- Registrar venta: descuenta del stock en una sola operación (evita vender lo que no hay
-- aunque dos personas carguen ventas al mismo tiempo). p_kg es la cantidad en la unidad
-- del producto (kg o unidades). p_pagado es lo que pagó en el momento (el resto queda
-- debiendo) y p_medio cómo lo pagó; la app exige el medio, la base lo acepta vacío por
-- compatibilidad con páginas viejas.
create function registrar_venta(p_producto uuid, p_kg numeric, p_total numeric, p_formato text, p_cliente text,
                                p_pagado numeric, p_medio text)
returns void language plpgsql set search_path = public as $$
declare
  v_prod productos;
  v_unidad text;
  v_venta uuid;
begin
  if p_kg is null or p_kg <= 0 then
    raise exception 'La cantidad tiene que ser mayor a 0.';
  end if;
  if p_total is null or p_total < 0 then
    raise exception 'Revisá el total.';
  end if;
  if p_pagado is null or p_pagado < 0 or p_pagado > p_total then
    raise exception 'Lo que pagó tiene que estar entre 0 y el total de la venta.';
  end if;
  if p_medio is not null and p_medio not in ('efectivo', 'transferencia') then
    raise exception 'El medio de pago tiene que ser efectivo o transferencia.';
  end if;
  select * into v_prod from productos where id = p_producto for update;
  if not found then
    raise exception 'El producto no existe.';
  end if;
  if v_prod.unidad = 'unidad' and p_kg <> trunc(p_kg) then
    raise exception 'Las unidades tienen que ser un número entero.';
  end if;
  if v_prod.cantidad < p_kg then
    v_unidad := case v_prod.unidad when 'unidad' then 'unidades' else 'kg' end;
    raise exception 'Solo hay % % de "%" en stock.', replace(trim_scale(v_prod.cantidad)::text, '.', ','), v_unidad, v_prod.nombre;
  end if;
  update productos set cantidad = cantidad - p_kg where id = p_producto;
  insert into ventas (producto_id, nombre, cantidad, unidad, precio_unit, total, pagado, formato, cliente)
  values (p_producto, v_prod.nombre, p_kg, v_prod.unidad, round(p_total / p_kg, 2), p_total, p_pagado,
          nullif(trim(p_formato), ''), nullif(trim(p_cliente), ''))
  returning id into v_venta;
  if p_pagado > 0 then
    insert into pagos (venta_id, monto, medio) values (v_venta, p_pagado, p_medio);
  end if;
end $$;

-- Versión anterior (páginas viejas guardadas en el celular): venta pagada completa, sin medio
create function registrar_venta(p_producto uuid, p_kg numeric, p_total numeric, p_formato text, p_cliente text)
returns void language sql set search_path = public as $$
  select registrar_venta(p_producto, p_kg, p_total, p_formato, p_cliente, p_total, null::text);
$$;

-- Cobrar (todo o parte de) lo que se debe de una venta
create function registrar_cobro(p_venta uuid, p_monto numeric, p_medio text)
returns void language plpgsql set search_path = public as $$
declare
  v ventas;
begin
  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto tiene que ser mayor a 0.';
  end if;
  if p_medio is null or p_medio not in ('efectivo', 'transferencia') then
    raise exception 'Elegí si pagó en efectivo o por transferencia.';
  end if;
  select * into v from ventas where id = p_venta for update;
  if not found then
    raise exception 'La venta ya no existe.';
  end if;
  if p_monto > v.total - v.pagado then
    raise exception 'Debe $%; no se puede cobrar más que eso.', replace(to_char(v.total - v.pagado, 'FM999,999,990'), ',', '.');
  end if;
  update ventas set pagado = pagado + p_monto where id = p_venta;
  insert into pagos (venta_id, monto, medio) values (p_venta, p_monto, p_medio);
end $$;

-- Anular venta: la borra y devuelve los kg al stock
create function anular_venta(p_venta uuid)
returns void language plpgsql set search_path = public as $$
declare
  v ventas;
begin
  delete from ventas where id = p_venta returning * into v;
  if not found then
    raise exception 'La venta ya no existe.';
  end if;
  if v.producto_id is not null then
    update productos set cantidad = cantidad + v.cantidad where id = v.producto_id;
  end if;
end $$;

revoke execute on function cargar_stock(text, numeric, numeric, text)                from public, anon;
revoke execute on function registrar_venta(uuid, numeric, numeric, text, text)  from public, anon;
revoke execute on function anular_venta(uuid)                                   from public, anon;
revoke execute on function registrar_venta(uuid, numeric, numeric, text, text, numeric, text) from public, anon;
revoke execute on function registrar_cobro(uuid, numeric, text)                 from public, anon;
grant  execute on function cargar_stock(text, numeric, numeric, text)                to authenticated;
grant  execute on function registrar_venta(uuid, numeric, numeric, text, text)  to authenticated;
grant  execute on function anular_venta(uuid)                                   to authenticated;
grant  execute on function registrar_venta(uuid, numeric, numeric, text, text, numeric, text) to authenticated;
grant  execute on function registrar_cobro(uuid, numeric, text)                 to authenticated;

-- ---------- Tiempo real: que todos vean los cambios al instante ----------
alter publication supabase_realtime add table productos, ventas, formatos, pagos;
