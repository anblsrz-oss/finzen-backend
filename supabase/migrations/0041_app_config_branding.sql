-- =====================================================================
-- Ahorbit — nombre y logo de la app configurables por admin.
-- app_title: null = usar "Mi Control de Finanzas Personales" por defecto.
-- logo_url: null = usar el emoji 💰 por defecto. Alojado en el bucket
-- público "branding" (primer uso de Supabase Storage en el proyecto).
-- RLS de update en app_config ya restringida a admin (0014). Re-ejecutable.
-- =====================================================================
alter table public.app_config
  add column if not exists app_title text,
  add column if not exists logo_url text;

insert into storage.buckets (id, name, public)
values ('branding', 'branding', true)
on conflict (id) do nothing;

drop policy if exists branding_public_read on storage.objects;
create policy branding_public_read on storage.objects for select
  using (bucket_id = 'branding');

drop policy if exists branding_admin_insert on storage.objects;
create policy branding_admin_insert on storage.objects for insert
  with check (
    bucket_id = 'branding'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  );

drop policy if exists branding_admin_update on storage.objects;
create policy branding_admin_update on storage.objects for update
  using (
    bucket_id = 'branding'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  )
  with check (
    bucket_id = 'branding'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  );

drop policy if exists branding_admin_delete on storage.objects;
create policy branding_admin_delete on storage.objects for delete
  using (
    bucket_id = 'branding'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  );
