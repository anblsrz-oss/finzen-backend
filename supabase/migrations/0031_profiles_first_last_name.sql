-- Nombre y apellido separados en el perfil.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name text;

-- El trigger que crea el perfil al registrarse ahora también copia
-- first_name/last_name desde el metadata (registro con contraseña usa
-- first_name/last_name; Google suele traer given_name/family_name), y deriva
-- full_name de full_name/name o de la concatenación nombre+apellido.
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_first text := coalesce(
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'given_name'
  );
  v_last text := coalesce(
    new.raw_user_meta_data ->> 'last_name',
    new.raw_user_meta_data ->> 'family_name'
  );
  v_full text := coalesce(
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    nullif(trim(concat_ws(' ', v_first, v_last)), '')
  );
begin
  insert into public.profiles (id, email, full_name, first_name, last_name, avatar_url)
  values (
    new.id,
    new.email,
    v_full,
    v_first,
    v_last,
    new.raw_user_meta_data ->> 'avatar_url'
  );
  return new;
end;
$function$;
