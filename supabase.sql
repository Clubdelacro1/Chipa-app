-- Chipa App: estructura de la base de datos.
-- Pegar todo esto en Supabase > SQL Editor > New query y apretar "Run".

-- ---------- Tablas ----------
create table productos (
  id       uuid primary key default gen_random_uuid(),
  nombre   text not null check (length(trim(nombre)) > 0),
  cantidad integer not null default 0 check (cantidad >= 0),
  precio   numeric(12,2) not null check (precio >= 0),
  creado   timestamptz not null default now()
);
-- No se puede repetir un producto con el mismo nombre (sin importar mayúsculas)
create unique index productos_nombre_unico on productos (lower(nombre));

create table ventas (
  id          uuid primary key default gen_random_uuid(),
  fecha       timestamptz not null default now(),
  producto_id uuid references productos(id) on delete set null,
  nombre      text not null,
  cantidad    integer not null check (cantidad > 0),
  precio_unit numeric(12,2) not null check (precio_unit >= 0),
  total       numeric(14,2) generated always as (cantidad * precio_unit) stored,
  vendedor    text default (auth.jwt() ->> 'email')
);
create index ventas_fecha on ventas (fecha desc);

-- Totales para mostrar arriba en la app
create view resumen with (security_invoker = true) as
select
  (select coalesce(sum(cantidad * precio), 0) from productos) as total_stock,
  (select coalesce(sum(total), 0) from ventas)                as total_ventas;

-- ---------- Seguridad: solo usuarios logueados ----------
alter table productos enable row level security;
alter table ventas    enable row level security;

create policy "usuarios logueados" on productos
  for all to authenticated using (true) with check (true);
create policy "usuarios logueados" on ventas
  for all to authenticated using (true) with check (true);

-- ---------- Operaciones ----------
-- Cargar stock: si el producto ya existe suma la cantidad y actualiza el precio
create or replace function cargar_stock(p_nombre text, p_cantidad integer, p_precio numeric)
returns void language sql as $$
  insert into productos (nombre, cantidad, precio)
  values (trim(p_nombre), p_cantidad, p_precio)
  on conflict ((lower(nombre))) do update
    set cantidad = productos.cantidad + excluded.cantidad,
        precio   = excluded.precio;
$$;

-- Registrar venta: descuenta del stock en una sola operación (evita vender lo que no hay
-- aunque dos personas carguen ventas al mismo tiempo)
create or replace function registrar_venta(p_producto uuid, p_cantidad integer, p_precio numeric)
returns void language plpgsql as $$
declare
  v_prod productos;
begin
  if p_cantidad is null or p_cantidad < 1 then
    raise exception 'La cantidad tiene que ser al menos 1.';
  end if;
  select * into v_prod from productos where id = p_producto for update;
  if not found then
    raise exception 'El producto no existe.';
  end if;
  if v_prod.cantidad < p_cantidad then
    raise exception 'Solo hay % de "%" en stock.', v_prod.cantidad, v_prod.nombre;
  end if;
  update productos set cantidad = cantidad - p_cantidad where id = p_producto;
  insert into ventas (producto_id, nombre, cantidad, precio_unit)
  values (p_producto, v_prod.nombre, p_cantidad, p_precio);
end $$;

-- Anular venta: la borra y devuelve la cantidad al stock
create or replace function anular_venta(p_venta uuid)
returns void language plpgsql as $$
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

revoke execute on function cargar_stock(text, integer, numeric)     from public, anon;
revoke execute on function registrar_venta(uuid, integer, numeric)  from public, anon;
revoke execute on function anular_venta(uuid)                       from public, anon;
grant  execute on function cargar_stock(text, integer, numeric)     to authenticated;
grant  execute on function registrar_venta(uuid, integer, numeric)  to authenticated;
grant  execute on function anular_venta(uuid)                       to authenticated;

alter function cargar_stock(text, integer, numeric)    set search_path = public;
alter function registrar_venta(uuid, integer, numeric) set search_path = public;
alter function anular_venta(uuid)                      set search_path = public;

-- ---------- Tiempo real: que todos vean los cambios al instante ----------
alter publication supabase_realtime add table productos, ventas;
