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
  formato     text,                                         -- "1 kg", "1/2 kg x3", "Otro"...
  cliente     text,                                         -- a quién se le vendió
  vendedor    text default (auth.jwt() ->> 'email'),
  unidad      text not null default 'kg' check (unidad in ('kg', 'unidad'))
);
create index ventas_fecha on ventas (fecha desc);

-- Formatos de venta (botones de la pestaña Ventas), editables desde la app
create table formatos (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null check (length(trim(nombre)) > 0),
  kg     numeric(10,3) check (kg > 0),        -- kg que descuenta del stock (null = falta cargar)
  precio numeric(12,2) check (precio >= 0),   -- precio fijo (null = según precio por kg)
  orden  integer not null default 0
);
create unique index formatos_nombre_unico on formatos (lower(nombre));

insert into formatos (nombre, kg, precio, orden) values
  ('1 kg',         1,    null,   1),
  ('1/2 kg',       0.5,  null,   2),
  ('1/4 kg',       0.25, null,   3),
  ('10 kg',        10,   165500, 4),
  ('12 unidades',  0.36, 10000,  5),
  ('6 unidades',   0.18, 6000,   6);

-- Totales para mostrar arriba en la app
create view resumen with (security_invoker = true) as
select
  (select coalesce(sum(cantidad * precio), 0) from productos) as total_stock,
  (select coalesce(sum(total), 0) from ventas)                as total_ventas;

-- ---------- Seguridad: solo usuarios logueados ----------
alter table productos enable row level security;
alter table ventas    enable row level security;
alter table formatos  enable row level security;

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

-- Registrar venta: descuenta del stock en una sola operación (evita vender lo que no hay
-- aunque dos personas carguen ventas al mismo tiempo). p_kg es la cantidad en la unidad
-- del producto (kg o unidades).
create function registrar_venta(p_producto uuid, p_kg numeric, p_total numeric, p_formato text, p_cliente text)
returns void language plpgsql set search_path = public as $$
declare
  v_prod productos;
  v_unidad text;
begin
  if p_kg is null or p_kg <= 0 then
    raise exception 'La cantidad tiene que ser mayor a 0.';
  end if;
  if p_total is null or p_total < 0 then
    raise exception 'Revisá el total.';
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
  insert into ventas (producto_id, nombre, cantidad, unidad, precio_unit, total, formato, cliente)
  values (p_producto, v_prod.nombre, p_kg, v_prod.unidad, round(p_total / p_kg, 2), p_total,
          nullif(trim(p_formato), ''), nullif(trim(p_cliente), ''));
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
grant  execute on function cargar_stock(text, numeric, numeric, text)                to authenticated;
grant  execute on function registrar_venta(uuid, numeric, numeric, text, text)  to authenticated;
grant  execute on function anular_venta(uuid)                                   to authenticated;

-- ---------- Tiempo real: que todos vean los cambios al instante ----------
alter publication supabase_realtime add table productos, ventas, formatos;
