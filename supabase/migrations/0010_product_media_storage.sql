-- Migration 0010: public product-media bucket. Anyone can view files by URL; only staff with
-- 'media.manage' (Super Admin, Admin, Product Manager, Content Manager) can upload, replace or delete.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-media', 'product-media', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/avif'])
on conflict (id) do nothing;

create policy "product_media_staff_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-media' and public.has_permission('media.manage'));
create policy "product_media_staff_update" on storage.objects for update to authenticated
  using (bucket_id = 'product-media' and public.has_permission('media.manage'))
  with check (bucket_id = 'product-media' and public.has_permission('media.manage'));
create policy "product_media_staff_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-media' and public.has_permission('media.manage'));
