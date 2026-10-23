-- =====================================================================
-- سكني (Sakani) — تصميم قاعدة البيانات لـ Supabase / PostgreSQL
-- =====================================================================
-- طريقة التشغيل:
--   1) أنشئ مشروع Supabase، وفعّل Phone Auth (مزود رسائل SMS يدعم عُمان).
--   2) شغّل هذا الملف كله في SQL Editor.
--   3) لو وقف في آخره بخطأ يخص cron: فعّل pg_cron من Database > Extensions،
--      ثم أعد تشغيل القسم 13 فقط.
--   4) سجّل بحسابك أنت في التطبيق، ثم شغّل (مرة وحدة):
--        insert into admins (user_id)
--        select id from profiles where phone = '968XXXXXXXX';  -- رقمك بصيغة دولية
--
-- ملاحظات تصميم:
--   * المبالغ numeric(8,3): الريال العُماني فيه 3 خانات (بيسة).
--   * ما أحد يكتب في bookings أو reviews أو payments مباشرة؛ كل شي عبر الدوال أدناه.
--   * الحجز بدون دفع: المقاعد تنحجز فورًا (pending)، المالك يتواصل ثم يؤكد أو يرفض،
--     وإذا ما رد خلال 72 ساعة يُلغى الحجز وترجع المقاعد. الدفع الوحيد: رسوم نشر الإعلان.
--   * لم يتم تشغيل هذا الملف على قاعدة بيانات فعلية بعد: اختبره على مشروع تجريبي أولًا.
-- =====================================================================

-- ---------- 1) الأنواع ----------
create type user_role      as enum ('student', 'housing_owner', 'bus_owner');
create type user_status    as enum ('active', 'suspended');
create type gender_t       as enum ('m', 'f');
create type listing_status as enum ('pending', 'approved', 'rejected', 'active', 'paused', 'expired');
create type room_type      as enum ('single', 'double', 'triple', 'quad');
create type rental_type    as enum ('monthly', 'semester', 'yearly');
create type apt_status     as enum ('available', 'held', 'rented');
create type booking_kind   as enum ('room', 'apartment', 'bus');
create type booking_status as enum ('pending', 'confirmed', 'rejected', 'cancelled', 'expired');
create type payment_kind   as enum ('listing_fee');   -- الطالب ما يدفع في التطبيق؛ المدفوعات فقط رسوم نشر الإعلان
create type payment_status as enum ('pending', 'paid', 'failed', 'refunded');
create type media_kind     as enum ('property', 'rooms', 'apartment', 'bus');
create type doc_kind       as enum ('national_id', 'ownership', 'driver_license', 'vehicle_registration');

-- ---------- 2) الجداول المرجعية (يديرها المشرف) ----------
create table governorates (
  id   smallint generated always as identity primary key,
  name text not null unique
);
create table wilayats (
  id             int generated always as identity primary key,
  governorate_id smallint not null references governorates(id),
  name           text not null,
  unique (governorate_id, name)
);
create table colleges (
  id             int generated always as identity primary key,
  governorate_id smallint not null references governorates(id),
  name           text not null,
  active         boolean not null default true,
  unique (governorate_id, name)
);

-- ---------- 3) المستخدمون ----------
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  phone      text unique,
  email      text,
  roles      user_role[] not null default '{}',
  gender     gender_t,
  college_id int references colleges(id),
  status     user_status not null default 'active',
  verified   boolean not null default false,
  created_at timestamptz not null default now()
);
-- المشرفون في جدول منفصل حتى ما أحد يرقّي نفسه
create table admins (user_id uuid primary key references auth.users(id) on delete cascade);

-- ---------- 4) الإعلانات ----------
create table properties (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null references profiles(id) on delete cascade,
  name                 text not null,
  governorate_id       smallint not null references governorates(id),
  area                 text not null,
  contact_phone        text not null check (contact_phone ~ '^[79][0-9]{7}$'),   -- رقم التواصل (جوال أو واتساب)
  gender               gender_t not null,            -- طلاب (m) أو طالبات (f)
  distance_km          numeric(5,1),
  rental               rental_type not null default 'monthly',
  map_url              text,                          -- اختياري للسكن
  note                 text,
  services             text[] not null default '{}',
  status               listing_status not null default 'pending',
  rejection_reason     text,
  verified             boolean not null default false,
  paused_by_suspension boolean not null default false,
  expires_at           timestamptz,
  created_at           timestamptz not null default now()
);

create table rooms (
  id               uuid primary key default gen_random_uuid(),
  property_id      uuid not null references properties(id) on delete cascade,
  name             text not null,
  type             room_type not null,
  capacity         smallint not null check (capacity between 1 and 8),
  price_per_person numeric(8,3) not null check (price_per_person > 0),
  seats_free       smallint not null,
  seats_outside    smallint not null default 0,      -- محجوز من خارج التطبيق (يعدله المالك)
  constraint rooms_seats_ok check (seats_free >= 0 and seats_outside >= 0 and seats_free + seats_outside <= capacity)
);

-- شقق كاملة: لسكن الطلاب (m) فقط
create table apartments (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null references properties(id) on delete cascade,
  name           text not null,
  bedrooms       smallint not null check (bedrooms between 1 and 10),
  price          numeric(8,3) not null check (price > 0),
  status         apt_status not null default 'available',
  rented_outside boolean not null default false
);

create table bus_services (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null references profiles(id) on delete cascade,
  name                 text not null,
  governorate_id       smallint not null references governorates(id),  -- محافظة الجامعة
  from_wilayat_id      int not null references wilayats(id),
  from_area            text not null,
  contact_phone        text not null check (contact_phone ~ '^[79][0-9]{7}$'),
  via_wilayat_ids      int[] not null default '{}',
  via_note             text,
  go_time              time not null,
  back_time            time not null,
  days                 smallint[] not null check (cardinality(days) > 0 and days <@ array[0,1,2,3,4,5,6]::smallint[]),  -- 0 = الأحد
  price_monthly        numeric(8,3) not null check (price_monthly > 0),
  capacity             smallint not null check (capacity > 0),
  seats_free           smallint not null,
  seats_outside        smallint not null default 0,
  vehicle              text not null,
  services             text[] not null default '{}',   -- مثل: متوفر 24 ساعة
  note                 text,
  status               listing_status not null default 'pending',
  rejection_reason     text,
  verified             boolean not null default false,
  paused_by_suspension boolean not null default false,
  expires_at           timestamptz,
  created_at           timestamptz not null default now(),
  constraint bus_seats_ok check (seats_free >= 0 and seats_outside >= 0 and seats_free + seats_outside <= capacity)
);

-- صور الإعلانات (عامة للقراءة) — الملفات في Storage
create table listing_media (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid references properties(id) on delete cascade,
  apartment_id uuid references apartments(id) on delete cascade,
  bus_id       uuid references bus_services(id) on delete cascade,
  kind         media_kind not null,
  storage_path text not null,
  sort         smallint not null default 0,
  check (num_nonnulls(property_id, bus_id) = 1)
);

-- وثائق التوثيق (بطاقة، ملكية، رخصة، استمارة) — خاصة، للمشرف وصاحبها فقط
create table verification_docs (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references profiles(id) on delete cascade,
  property_id  uuid references properties(id) on delete cascade,
  bus_id       uuid references bus_services(id) on delete cascade,
  kind         doc_kind not null,
  storage_path text not null,
  created_at   timestamptz not null default now(),
  check (num_nonnulls(property_id, bus_id) = 1)
);

-- ---------- 5) المدفوعات والحجوزات ----------
-- المدفوعات: رسوم نشر الإعلان فقط (5 ر.ع لمدة 4 أشهر). تُدفع يدويًا عبر واتساب بعد موافقتك،
-- وأنت تسجّل استلامها بالدالة admin_confirm_listing_paid فينزل الإعلان.
create table payments (
  id          uuid primary key default gen_random_uuid(),
  kind        payment_kind not null default 'listing_fee',
  payer_id    uuid not null references profiles(id),
  amount      numeric(8,3) not null check (amount > 0),
  currency    char(3) not null default 'OMR',
  gateway     text not null default 'manual',          -- manual = دفع عبر واتساب/تحويل، يمكن لاحقًا ربط بوابة
  gateway_ref text unique,
  status      payment_status not null default 'pending',
  property_id uuid references properties(id),
  bus_id      uuid references bus_services(id),
  created_at  timestamptz not null default now(),
  paid_at     timestamptz,
  check (num_nonnulls(property_id, bus_id) = 1)
);

-- الحجز بدون دفع: الطالب يرسل الحجز، المقاعد تُحجز له فورًا (pending)،
-- المالك يتواصل معه ثم يؤكد (confirmed) أو يرفض (rejected) فترجع المقاعد.
-- إذا ما رد المالك خلال 72 ساعة يُلغى الحجز تلقائيًا وترجع المقاعد (expired).
create sequence booking_ref_seq start 100000;
create table bookings (
  id           uuid primary key default gen_random_uuid(),
  ref          text not null unique default ('SK' || nextval('booking_ref_seq')::text),
  student_id   uuid not null references profiles(id),
  kind         booking_kind not null,
  property_id  uuid references properties(id),
  room_id      uuid references rooms(id),
  apartment_id uuid references apartments(id),
  bus_id       uuid references bus_services(id),
  seats        smallint not null check (seats > 0),
  total        numeric(8,3) not null check (total > 0),   -- السعر للعلم فقط، يتفق عليه الطالب مع المالك
  message      text check (length(message) <= 300),
  status       booking_status not null default 'pending',
  expires_at   timestamptz,                                -- مهلة رد المالك
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  check ((kind = 'room' and room_id is not null) or (kind = 'apartment' and apartment_id is not null) or (kind = 'bus' and bus_id is not null))
);

-- المستأجرون في العقد (الطالب + أصدقاؤه). الرقم المدني حساس:
-- فعّل تشفير العمود (Supabase Vault / pgsodium) قبل الإطلاق.
create table booking_tenants (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id) on delete cascade,
  full_name  text not null,
  civil_id   text not null check (civil_id ~ '^[0-9]{7,9}$')
);

-- ---------- 6) بقية الميزات ----------
create table favorites (
  user_id     uuid not null references profiles(id) on delete cascade,
  property_id uuid references properties(id) on delete cascade,
  bus_id      uuid references bus_services(id) on delete cascade,
  created_at  timestamptz not null default now(),
  check (num_nonnulls(property_id, bus_id) = 1)
);
create unique index favorites_property_uq on favorites (user_id, property_id) where property_id is not null;
create unique index favorites_bus_uq      on favorites (user_id, bus_id)      where bus_id is not null;

create table conversations (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references profiles(id) on delete cascade,
  owner_id    uuid not null references profiles(id) on delete cascade,
  property_id uuid references properties(id) on delete set null,
  bus_id      uuid references bus_services(id) on delete set null,
  created_at  timestamptz not null default now()
);
create table messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id),
  body            text not null check (length(body) between 1 and 2000),
  created_at      timestamptz not null default now()
);

-- الشكاوى: على إعلان محدد أو عامة (property_id و bus_id كلاهما null)
create table reports (
  id            uuid primary key default gen_random_uuid(),
  reporter_id   uuid not null references profiles(id) on delete cascade,
  property_id   uuid references properties(id) on delete set null,
  bus_id        uuid references bus_services(id) on delete set null,
  reason        text not null,
  details       text not null check (length(details) >= 5),
  contact_phone text not null check (contact_phone ~ '^[79][0-9]{7}$'),
  status        text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  admin_note    text,
  created_at    timestamptz not null default now(),
  handled_at    timestamptz,
  check (num_nonnulls(property_id, bus_id) <= 1)
);

-- التقييمات: فقط للطالب اللي أكد المالك حجزه (تُكتب عبر submit_review)
create table reviews (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references profiles(id) on delete cascade,
  property_id uuid references properties(id) on delete cascade,
  bus_id      uuid references bus_services(id) on delete cascade,
  stars       smallint not null check (stars between 1 and 5),
  comment     text check (length(comment) <= 200),
  hidden      boolean not null default false,      -- يخفيه المشرف إذا مسيء
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (num_nonnulls(property_id, bus_id) = 1)
);
create unique index reviews_property_uq on reviews (student_id, property_id) where property_id is not null;
create unique index reviews_bus_uq      on reviews (student_id, bus_id)      where bus_id is not null;

create view property_ratings as
  select property_id, round(avg(stars)::numeric, 1) as avg_stars, count(*) as reviews
  from reviews where not hidden and property_id is not null group by property_id;
create view bus_ratings as
  select bus_id, round(avg(stars)::numeric, 1) as avg_stars, count(*) as reviews
  from reviews where not hidden and bus_id is not null group by bus_id;
grant select on property_ratings, bus_ratings to anon, authenticated;

create table audit_log (
  id           bigint generated always as identity primary key,
  admin_id     uuid,
  action       text not null,
  target_table text,
  target_id    uuid,
  details      jsonb,
  created_at   timestamptz not null default now()
);

create index on properties (status, governorate_id, gender);
create index on rooms (property_id);
create index on apartments (property_id);
create index on bus_services (status, governorate_id);
create index on bookings (student_id);
create index on bookings (status, expires_at);

-- ---------- 7) دوال مساعدة وتريقرات ----------
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

-- إنشاء الملف الشخصي تلقائيًا بعد التسجيل
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, phone, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', '—'), new.phone, new.email);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- المالك ما يغيّر الحالة/التوثيق/الانتهاء بنفسه (الأدوار الداخلية تتخطى هذا الفحص)
create function lock_listing_columns() returns trigger language plpgsql as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.verified := false; new.expires_at := null;
    new.rejection_reason := null; new.paused_by_suspension := false;
  else
    new.status := old.status; new.verified := old.verified; new.expires_at := old.expires_at;
    new.rejection_reason := old.rejection_reason; new.paused_by_suspension := old.paused_by_suspension;
  end if;
  return new;
end $$;
create trigger trg_01_lock before insert or update on properties
  for each row execute function lock_listing_columns();
create trigger trg_01_lock before insert or update on bus_services
  for each row execute function lock_listing_columns();

create function lock_profile_columns() returns trigger language plpgsql as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'active'; new.verified := false;
  else
    new.status := old.status; new.verified := old.verified; new.phone := old.phone;
  end if;
  return new;
end $$;
create trigger trg_01_lock before insert or update on profiles
  for each row execute function lock_profile_columns();

-- المقاعد تبدأ كاملة عند الإنشاء
create function init_seats() returns trigger language plpgsql as $$
begin
  new.seats_free := new.capacity;
  new.seats_outside := 0;
  return new;
end $$;
create trigger trg_init_seats before insert on rooms
  for each row execute function init_seats();
create trigger trg_init_seats before insert on bus_services
  for each row execute function init_seats();

-- الشقة الكاملة لسكن الطلاب فقط
create function enforce_boys_apartments() returns trigger language plpgsql as $$
begin
  if (select gender from properties where id = new.property_id) <> 'm' then
    raise exception 'الشقة الكاملة متاحة لسكن الطلاب فقط';
  end if;
  if tg_op = 'INSERT' then new.status := 'available'; new.rented_outside := false; end if;
  return new;
end $$;
create trigger trg_boys_apartments before insert on apartments
  for each row execute function enforce_boys_apartments();

-- أي تغيير في السعر بعد الموافقة يرجع الإعلان للمراجعة
create function review_on_room_price() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.price_per_person is distinct from old.price_per_person then
    update properties set status = 'pending' where id = new.property_id and status in ('active', 'approved');
  end if;
  return new;
end $$;
create trigger trg_room_price after update of price_per_person on rooms
  for each row execute function review_on_room_price();

create function review_on_apartment_price() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.price is distinct from old.price then
    update properties set status = 'pending' where id = new.property_id and status in ('active', 'approved');
  end if;
  return new;
end $$;
create trigger trg_apartment_price after update of price on apartments
  for each row execute function review_on_apartment_price();

create function review_on_bus_price() returns trigger language plpgsql as $$
begin
  if new.price_monthly is distinct from old.price_monthly and old.status in ('active', 'approved') then
    new.status := 'pending';
  end if;
  return new;
end $$;
create trigger trg_02_price before update of price_monthly on bus_services
  for each row execute function review_on_bus_price();

-- ---------- 8) الحجز بدون دفع وبدون تعارض ----------
create function validate_tenants(p_tenants jsonb, p_expected int) returns void
language plpgsql as $$
begin
  if jsonb_typeof(p_tenants) <> 'array' or jsonb_array_length(p_tenants) <> p_expected then
    raise exception 'عدد المستأجرين لازم يساوي %', p_expected;
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_tenants) t
    where coalesce(trim(t->>'full_name'), '') = '' or coalesce(t->>'civil_id', '') !~ '^[0-9]{7,9}$'
  ) then
    raise exception 'أكمل اسم ورقم مدني (7 إلى 9 أرقام) لكل مستأجر';
  end if;
end $$;

-- p_tenants مثال: [{"full_name":"سالم","civil_id":"12345678"},{"full_name":"علي","civil_id":"87654321"}]
create function book_room(p_room_id uuid, p_seats int, p_tenants jsonb, p_message text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_stu profiles%rowtype; v_room rooms%rowtype; v_prop properties%rowtype; v_id uuid;
begin
  select * into v_stu from profiles where id = auth.uid();
  if v_stu.id is null or v_stu.status <> 'active' or not ('student' = any(v_stu.roles)) then
    raise exception 'الحجز للطلاب المفعّلين فقط';
  end if;
  select * into v_room from rooms where id = p_room_id for update;   -- قفل الصف: يمنع الحجز المزدوج
  if not found then raise exception 'الغرفة غير موجودة'; end if;
  select * into v_prop from properties where id = v_room.property_id;
  if v_prop.status <> 'active' or v_prop.expires_at <= now() then raise exception 'الإعلان غير متاح'; end if;
  if v_prop.gender is distinct from v_stu.gender then raise exception 'هذا السكن لفئة أخرى'; end if;
  perform validate_tenants(p_tenants, p_seats);
  if v_room.seats_free < p_seats then raise exception 'المقاعد المتاحة الآن: %', v_room.seats_free; end if;

  update rooms set seats_free = seats_free - p_seats where id = p_room_id;
  insert into bookings (student_id, kind, property_id, room_id, seats, total, message, expires_at)
  values (auth.uid(), 'room', v_prop.id, p_room_id, p_seats, p_seats * v_room.price_per_person, p_message, now() + interval '72 hours')
  returning id into v_id;
  insert into booking_tenants (booking_id, full_name, civil_id)
  select v_id, trim(t->>'full_name'), t->>'civil_id' from jsonb_array_elements(p_tenants) t;
  return v_id;
end $$;

create function book_apartment(p_apartment_id uuid, p_tenants jsonb, p_message text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_stu profiles%rowtype; v_apt apartments%rowtype; v_prop properties%rowtype; v_id uuid; v_n int;
begin
  select * into v_stu from profiles where id = auth.uid();
  if v_stu.id is null or v_stu.status <> 'active' or not ('student' = any(v_stu.roles)) then
    raise exception 'الحجز للطلاب المفعّلين فقط';
  end if;
  select * into v_apt from apartments where id = p_apartment_id for update;
  if not found then raise exception 'الشقة غير موجودة'; end if;
  select * into v_prop from properties where id = v_apt.property_id;
  if v_prop.status <> 'active' or v_prop.expires_at <= now() then raise exception 'الإعلان غير متاح'; end if;
  if v_prop.gender <> 'm' or v_stu.gender is distinct from 'm' then raise exception 'الشقة الكاملة للطلاب فقط'; end if;
  if v_apt.status <> 'available' then raise exception 'الشقة انحجزت قبل شوي'; end if;
  v_n := case when jsonb_typeof(p_tenants) = 'array' then jsonb_array_length(p_tenants) else 0 end;
  if v_n < 1 or v_n > 8 then raise exception 'عدد المستأجرين من 1 إلى 8'; end if;
  perform validate_tenants(p_tenants, v_n);

  update apartments set status = 'held' where id = p_apartment_id;
  insert into bookings (student_id, kind, property_id, apartment_id, seats, total, message, expires_at)
  values (auth.uid(), 'apartment', v_prop.id, p_apartment_id, v_n, v_apt.price, p_message, now() + interval '72 hours')
  returning id into v_id;
  insert into booking_tenants (booking_id, full_name, civil_id)
  select v_id, trim(t->>'full_name'), t->>'civil_id' from jsonb_array_elements(p_tenants) t;
  return v_id;
end $$;

create function book_bus(p_bus_id uuid, p_seats int, p_tenants jsonb, p_message text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_stu profiles%rowtype; v_bus bus_services%rowtype; v_id uuid;
begin
  select * into v_stu from profiles where id = auth.uid();
  if v_stu.id is null or v_stu.status <> 'active' or not ('student' = any(v_stu.roles)) then
    raise exception 'الحجز للطلاب المفعّلين فقط';
  end if;
  select * into v_bus from bus_services where id = p_bus_id for update;
  if not found then raise exception 'الخدمة غير موجودة'; end if;
  if v_bus.status <> 'active' or v_bus.expires_at <= now() then raise exception 'الخدمة غير متاحة'; end if;
  perform validate_tenants(p_tenants, p_seats);
  if v_bus.seats_free < p_seats then raise exception 'المقاعد المتاحة الآن: %', v_bus.seats_free; end if;

  update bus_services set seats_free = seats_free - p_seats where id = p_bus_id;
  insert into bookings (student_id, kind, bus_id, seats, total, message, expires_at)
  values (auth.uid(), 'bus', p_bus_id, p_seats, p_seats * v_bus.price_monthly, p_message, now() + interval '72 hours')
  returning id into v_id;
  insert into booking_tenants (booking_id, full_name, civil_id)
  select v_id, trim(t->>'full_name'), t->>'civil_id' from jsonb_array_elements(p_tenants) t;
  return v_id;
end $$;

-- إرجاع المقاعد (داخلية)
create function release_seats(b bookings) returns void
language plpgsql security definer set search_path = public as $$
begin
  if b.kind = 'room' then
    update rooms set seats_free = least(capacity, seats_free + b.seats) where id = b.room_id;
  elsif b.kind = 'apartment' then
    update apartments set status = 'available' where id = b.apartment_id;
  else
    update bus_services set seats_free = least(capacity, seats_free + b.seats) where id = b.bus_id;
  end if;
end $$;

-- الطالب يلغي حجزه قبل ما يؤكده المالك
create function cancel_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype;
begin
  select * into b from bookings where id = p_booking and student_id = auth.uid() for update;
  if not found or b.status <> 'pending' then raise exception 'لا يمكن إلغاء هذا الحجز'; end if;
  perform release_seats(b);
  update bookings set status = 'cancelled', decided_at = now() where id = p_booking;
end $$;

-- المالك: تأكيد الحجز بعد الاتفاق مع الطالب، أو رفضه (ترجع المقاعد)
create function owner_decide_booking(p_booking uuid, p_confirm boolean) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype;
begin
  select * into b from bookings where id = p_booking for update;
  if not found or b.status <> 'pending' then raise exception 'الحجز غير موجود أو تم البت فيه'; end if;
  if not (
    exists (select 1 from properties p where p.id = b.property_id and p.owner_id = auth.uid())
    or exists (select 1 from bus_services s where s.id = b.bus_id and s.owner_id = auth.uid())
  ) then raise exception 'هذا الحجز ليس على إعلانك'; end if;
  if not p_confirm then perform release_seats(b); end if;
  update bookings set status = case when p_confirm then 'confirmed'::booking_status else 'rejected'::booking_status end,
         decided_at = now() where id = p_booking;
  if p_confirm and b.kind = 'apartment' then
    update apartments set status = 'rented' where id = b.apartment_id;   -- الشقة تصير مؤجرة بعد التأكيد
  end if;
end $$;

-- إلغاء الحجوزات اللي ما رد عليها المالك خلال 72 ساعة (مجدولة، section 13)
create function expire_pending_bookings() returns int
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; n int := 0;
begin
  for b in select * from bookings where status = 'pending' and expires_at < now() for update skip locked loop
    perform release_seats(b);
    update bookings set status = 'expired', decided_at = now() where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- الطالب يقيّم بعد تأكيد حجزه (تقييم واحد لكل إعلان، يمكن تعديله)
create function submit_review(p_kind text, p_id uuid, p_stars int, p_comment text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_stars not between 1 and 5 then raise exception 'التقييم من 1 إلى 5'; end if;
  if p_kind = 'property' then
    if not exists (select 1 from bookings where student_id = auth.uid() and property_id = p_id and status = 'confirmed') then
      raise exception 'التقييم متاح للطالب اللي أكد المالك حجزه';
    end if;
    insert into reviews (student_id, property_id, stars, comment) values (auth.uid(), p_id, p_stars, nullif(trim(p_comment), ''))
    on conflict (student_id, property_id) where property_id is not null
    do update set stars = excluded.stars, comment = excluded.comment, updated_at = now();
  elsif p_kind = 'bus' then
    if not exists (select 1 from bookings where student_id = auth.uid() and bus_id = p_id and status = 'confirmed') then
      raise exception 'التقييم متاح للطالب اللي أكد المالك حجزه';
    end if;
    insert into reviews (student_id, bus_id, stars, comment) values (auth.uid(), p_id, p_stars, nullif(trim(p_comment), ''))
    on conflict (student_id, bus_id) where bus_id is not null
    do update set stars = excluded.stars, comment = excluded.comment, updated_at = now();
  else
    raise exception 'نوع غير معروف';
  end if;
end $$;

-- ---------- 9) تأكيد دفع رسوم النشر (يدوي عبر واتساب) ----------
-- المسار: المالك يرسل إعلانه ← أنت توافق (admin_review) ← تتواصل معه على واتساب وتستلم الرسوم
-- ← تضغط "تم استلام الدفع" فتُستدعى admin_confirm_listing_paid: يسجّل الدفعة وينشر الإعلان 4 أشهر.
create function admin_confirm_listing_paid(p_kind text, p_id uuid, p_amount numeric default 5, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  if p_kind = 'property' then
    update properties set status = 'active', expires_at = now() + interval '4 months'
    where id = p_id and status = 'approved' returning owner_id into v_owner;
  elsif p_kind = 'bus' then
    update bus_services set status = 'active', expires_at = now() + interval '4 months'
    where id = p_id and status = 'approved' returning owner_id into v_owner;
  else
    raise exception 'نوع غير معروف';
  end if;
  if v_owner is null then raise exception 'الإعلان غير موافق عليه بعد'; end if;
  insert into payments (kind, payer_id, amount, gateway, status, property_id, bus_id, paid_at)
  values ('listing_fee', v_owner, p_amount, 'manual', 'paid',
          case when p_kind = 'property' then p_id end, case when p_kind = 'bus' then p_id end, now());
  insert into audit_log (admin_id, action, target_table, target_id, details)
  values (auth.uid(), 'confirm_fee_paid', p_kind, p_id, jsonb_build_object('amount', p_amount, 'note', p_note));
end $$;

-- ---------- 10) دوال المالك والمشرف ----------
-- المالك: تعديل "حجز من خارج التطبيق" (+1 ينقص المتاح، -1 يرجّعه، فقط لما سجّله هو)
create function adjust_outside(p_kind text, p_id uuid, p_delta int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_delta not in (-1, 1) then raise exception 'القيمة +1 أو -1 فقط'; end if;
  if p_kind = 'room' then
    update rooms r set seats_free = r.seats_free - p_delta, seats_outside = r.seats_outside + p_delta
    from properties p
    where r.id = p_id and p.id = r.property_id and p.owner_id = auth.uid()
      and ((p_delta > 0 and r.seats_free > 0) or (p_delta < 0 and r.seats_outside > 0));
  elsif p_kind = 'bus' then
    update bus_services b set seats_free = b.seats_free - p_delta, seats_outside = b.seats_outside + p_delta
    where b.id = p_id and b.owner_id = auth.uid()
      and ((p_delta > 0 and b.seats_free > 0) or (p_delta < 0 and b.seats_outside > 0));
  elsif p_kind = 'apartment' then
    if p_delta > 0 then
      update apartments a set status = 'rented', rented_outside = true
      from properties p
      where a.id = p_id and p.id = a.property_id and p.owner_id = auth.uid() and a.status = 'available';
    else
      update apartments a set status = 'available', rented_outside = false
      from properties p
      where a.id = p_id and p.id = a.property_id and p.owner_id = auth.uid() and a.rented_outside;
    end if;
  else
    raise exception 'نوع غير معروف';
  end if;
  if not found then raise exception 'ما قدرنا نعدّل: تأكد من الصلاحية أو من الأعداد'; end if;
end $$;

-- المشرف: موافقة أو رفض (p_kind = 'property' أو 'bus')
create function admin_review(p_kind text, p_id uuid, p_approve boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  if p_kind = 'property' then
    update properties set
      status = case when p_approve then 'approved'::listing_status else 'rejected'::listing_status end,
      verified = p_approve,
      rejection_reason = case when p_approve then null else p_reason end
    where id = p_id and status = 'pending';
  elsif p_kind = 'bus' then
    update bus_services set
      status = case when p_approve then 'approved'::listing_status else 'rejected'::listing_status end,
      verified = p_approve,
      rejection_reason = case when p_approve then null else p_reason end
    where id = p_id and status = 'pending';
  else
    raise exception 'نوع غير معروف';
  end if;
  if not found then raise exception 'الإعلان غير موجود أو ليس بانتظار المراجعة'; end if;
  insert into audit_log (admin_id, action, target_table, target_id, details)
  values (auth.uid(), case when p_approve then 'approve' else 'reject' end, p_kind, p_id, jsonb_build_object('reason', p_reason));
end $$;

-- المشرف: إيقاف/تشغيل إعلان منشور
create function admin_set_listing_paused(p_kind text, p_id uuid, p_paused boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  if p_kind = 'property' then
    update properties set status = case when p_paused then 'paused'::listing_status else 'active'::listing_status end
    where id = p_id and status in ('active', 'paused');
  elsif p_kind = 'bus' then
    update bus_services set status = case when p_paused then 'paused'::listing_status else 'active'::listing_status end
    where id = p_id and status in ('active', 'paused');
  else
    raise exception 'نوع غير معروف';
  end if;
  insert into audit_log (admin_id, action, target_table, target_id)
  values (auth.uid(), case when p_paused then 'pause' else 'resume' end, p_kind, p_id);
end $$;

-- المشرف: إيقاف حساب (يوقف إعلاناته) أو إعادة تفعيله
create function admin_set_user_status(p_user uuid, p_suspend boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  update profiles set status = case when p_suspend then 'suspended'::user_status else 'active'::user_status end where id = p_user;
  if p_suspend then
    update properties   set status = 'paused', paused_by_suspension = true where owner_id = p_user and status = 'active';
    update bus_services set status = 'paused', paused_by_suspension = true where owner_id = p_user and status = 'active';
  else
    update properties   set status = 'active', paused_by_suspension = false where owner_id = p_user and paused_by_suspension;
    update bus_services set status = 'active', paused_by_suspension = false where owner_id = p_user and paused_by_suspension;
  end if;
  insert into audit_log (admin_id, action, target_table, target_id)
  values (auth.uid(), case when p_suspend then 'suspend_user' else 'reactivate_user' end, 'profiles', p_user);
end $$;

-- المشرف: توثيق حساب مالك (شارة ✓ على كل إعلاناته)
create function admin_set_verified(p_user uuid, p_verified boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  update profiles set verified = p_verified where id = p_user;
  update properties   set verified = p_verified where owner_id = p_user;
  update bus_services set verified = p_verified where owner_id = p_user;
  insert into audit_log (admin_id, action, target_table, target_id, details)
  values (auth.uid(), 'verify_user', 'profiles', p_user, jsonb_build_object('verified', p_verified));
end $$;

-- المشرف: إخفاء تقييم مسيء، ومعالجة شكوى
create function admin_hide_review(p_id uuid, p_hidden boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  update reviews set hidden = p_hidden where id = p_id;
  insert into audit_log (admin_id, action, target_table, target_id, details)
  values (auth.uid(), 'hide_review', 'reviews', p_id, jsonb_build_object('hidden', p_hidden));
end $$;

create function admin_handle_report(p_id uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  if p_status not in ('resolved', 'dismissed') then raise exception 'الحالة غير صحيحة'; end if;
  update reports set status = p_status, admin_note = nullif(trim(p_note), ''), handled_at = now() where id = p_id and status = 'open';
  if not found then raise exception 'الشكوى غير موجودة أو تمت معالجتها'; end if;
  insert into audit_log (admin_id, action, target_table, target_id, details)
  values (auth.uid(), 'handle_report', 'reports', p_id, jsonb_build_object('status', p_status));
end $$;

-- لوحة المشرف: أرقام الصفحة الرئيسية
create function admin_dashboard() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للمشرف فقط'; end if;
  return jsonb_build_object(
    'users',              (select count(*) from profiles),
    'students',           (select count(*) from profiles where 'student' = any(roles)),
    'housing_owners',     (select count(*) from profiles where 'housing_owner' = any(roles)),
    'bus_owners',         (select count(*) from profiles where 'bus_owner' = any(roles)),
    'suspended',          (select count(*) from profiles where status = 'suspended'),
    'pending_listings',   (select count(*) from properties where status = 'pending') + (select count(*) from bus_services where status = 'pending'),
    'active_listings',    (select count(*) from properties where status = 'active') + (select count(*) from bus_services where status = 'active'),
    'bookings_pending',   (select count(*) from bookings where status = 'pending'),
    'bookings_confirmed', (select count(*) from bookings where status = 'confirmed'),
    'bookings_value',     coalesce((select sum(total) from bookings where status = 'confirmed'), 0),
    'fees_revenue',       coalesce((select sum(amount) from payments where kind = 'listing_fee' and status = 'paid'), 0),
    'open_reports',       (select count(*) from reports where status = 'open'),
    'reviews',            (select count(*) from reviews where not hidden)
  );
end $$;

-- انتهاء مدة الإعلانات (4 أشهر)
create function expire_listings() returns void
language sql security definer set search_path = public as $$
  update properties   set status = 'expired' where status = 'active' and expires_at <= now();
  update bus_services set status = 'expired' where status = 'active' and expires_at <= now();
$$;

-- ---------- 11) الصلاحيات (RLS) ----------
alter table governorates       enable row level security;
alter table wilayats           enable row level security;
alter table colleges           enable row level security;
alter table profiles           enable row level security;
alter table admins             enable row level security;
alter table properties         enable row level security;
alter table rooms              enable row level security;
alter table apartments         enable row level security;
alter table bus_services       enable row level security;
alter table listing_media      enable row level security;
alter table verification_docs  enable row level security;
alter table payments           enable row level security;
alter table bookings           enable row level security;
alter table booking_tenants    enable row level security;
alter table favorites          enable row level security;
alter table conversations      enable row level security;
alter table messages           enable row level security;
alter table reports            enable row level security;
alter table reviews            enable row level security;
alter table audit_log          enable row level security;

-- الجداول المرجعية: قراءة للجميع، تعديل للمشرف
create policy ref_read_gov on governorates for select using (true);
create policy ref_read_wil on wilayats     for select using (true);
create policy ref_read_col on colleges     for select using (true);
create policy ref_admin_gov on governorates for all using (is_admin()) with check (is_admin());
create policy ref_admin_wil on wilayats     for all using (is_admin()) with check (is_admin());
create policy ref_admin_col on colleges     for all using (is_admin()) with check (is_admin());

-- الملفات الشخصية
create policy profiles_select_self on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_update_self on profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- المالك يشوف بيانات الطالب اللي حجز عنده (حجز معلّق أو مؤكد)
create policy profiles_select_booker on profiles for select using (
  exists (
    select 1 from bookings b
    left join properties p   on p.id = b.property_id
    left join bus_services s on s.id = b.bus_id
    where b.student_id = profiles.id and b.status in ('pending', 'confirmed')
      and (p.owner_id = auth.uid() or s.owner_id = auth.uid())
  )
);
-- بيانات المالك العامة للطلاب (الاسم والتوثيق فقط)
create view owner_public as
  select id, full_name, verified from profiles
  where 'housing_owner' = any(roles) or 'bus_owner' = any(roles);
grant select on owner_public to anon, authenticated;

-- الإعلانات: المنشور للجميع، والمالك يشوف إعلاناته، والمشرف الكل
create policy prop_select on properties for select using (
  (status = 'active' and expires_at > now()) or owner_id = auth.uid() or is_admin());
create policy prop_insert on properties for insert with check (
  owner_id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and 'housing_owner' = any(roles) and status = 'active'));
create policy prop_update on properties for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy prop_delete on properties for delete using (
  (owner_id = auth.uid() and status in ('pending', 'rejected')) or is_admin());

create policy bus_select on bus_services for select using (
  (status = 'active' and expires_at > now()) or owner_id = auth.uid() or is_admin());
create policy bus_insert on bus_services for insert with check (
  owner_id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and 'bus_owner' = any(roles) and status = 'active'));
create policy bus_update on bus_services for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy bus_delete on bus_services for delete using (
  (owner_id = auth.uid() and status in ('pending', 'rejected')) or is_admin());

-- الغرف والشقق: تُرى إذا الإعلان نفسه يُرى، ويعدلها مالك الإعلان
create policy rooms_select on rooms for select using (exists (select 1 from properties p where p.id = property_id));
create policy rooms_write  on rooms for all using (exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid()))
  with check (exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid()));
create policy apts_select on apartments for select using (exists (select 1 from properties p where p.id = property_id));
create policy apts_write  on apartments for all using (exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid()))
  with check (exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid()));

-- الصور
create policy media_select on listing_media for select using (
  exists (select 1 from properties p where p.id = property_id) or exists (select 1 from bus_services s where s.id = bus_id));
create policy media_write on listing_media for all using (
  exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid())
  or exists (select 1 from bus_services s where s.id = bus_id and s.owner_id = auth.uid()))
  with check (
  exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid())
  or exists (select 1 from bus_services s where s.id = bus_id and s.owner_id = auth.uid()));

-- وثائق التوثيق: صاحبها والمشرف فقط
create policy docs_select on verification_docs for select using (owner_id = auth.uid() or is_admin());
create policy docs_insert on verification_docs for insert with check (owner_id = auth.uid());
create policy docs_delete on verification_docs for delete using (owner_id = auth.uid() or is_admin());

-- الحجوزات والمدفوعات: قراءة فقط (الكتابة عبر الدوال)
create policy bookings_select on bookings for select using (
  student_id = auth.uid() or is_admin() or (status in ('pending', 'confirmed') and (
    exists (select 1 from properties p where p.id = property_id and p.owner_id = auth.uid())
    or exists (select 1 from bus_services s where s.id = bus_id and s.owner_id = auth.uid()))));
create policy tenants_select on booking_tenants for select using (exists (select 1 from bookings b where b.id = booking_id));
create policy payments_select on payments for select using (payer_id = auth.uid() or is_admin());

create policy fav_all on favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy conv_select on conversations for select using (student_id = auth.uid() or owner_id = auth.uid() or is_admin());
create policy conv_insert on conversations for insert with check (student_id = auth.uid());
create policy msg_select on messages for select using (
  exists (select 1 from conversations c where c.id = conversation_id and (c.student_id = auth.uid() or c.owner_id = auth.uid())) or is_admin());
create policy msg_insert on messages for insert with check (
  sender_id = auth.uid() and exists (select 1 from conversations c where c.id = conversation_id and (c.student_id = auth.uid() or c.owner_id = auth.uid())));

create policy reports_insert on reports for insert with check (reporter_id = auth.uid());
create policy reports_select on reports for select using (reporter_id = auth.uid() or is_admin());
create policy reviews_select on reviews for select using (
  student_id = auth.uid() or is_admin() or (not hidden and (
    exists (select 1 from properties p where p.id = property_id)
    or exists (select 1 from bus_services s where s.id = bus_id))));
create policy audit_admin on audit_log for select using (is_admin());

-- صلاحيات الأعمدة: المالك ما يعدّل المقاعد ولا الحالة مباشرة
revoke insert, update, delete on bookings, booking_tenants, payments, audit_log, reviews from authenticated, anon;
revoke all on admins from authenticated, anon;
revoke update on profiles, properties, rooms, apartments, bus_services from authenticated;
grant update (full_name, email, gender, college_id, roles) on profiles to authenticated;
grant update (name, governorate_id, area, contact_phone, distance_km, rental, map_url, note, services) on properties to authenticated;
grant update (name, type, capacity, price_per_person) on rooms to authenticated;
grant update (name, bedrooms, price) on apartments to authenticated;
grant update (name, governorate_id, from_wilayat_id, from_area, contact_phone, via_wilayat_ids, via_note, go_time, back_time, days, price_monthly, capacity, vehicle, services, note) on bus_services to authenticated;

-- من يقدر ينفذ الدوال
revoke execute on function release_seats(bookings),
  expire_pending_bookings(), expire_listings() from public, anon, authenticated;
grant  execute on function expire_pending_bookings(), expire_listings() to service_role;
revoke execute on function book_room(uuid, int, jsonb, text), book_apartment(uuid, jsonb, text), book_bus(uuid, int, jsonb, text),
  cancel_booking(uuid), owner_decide_booking(uuid, boolean), submit_review(text, uuid, int, text),
  adjust_outside(text, uuid, int), admin_review(text, uuid, boolean, text),
  admin_set_listing_paused(text, uuid, boolean), admin_set_user_status(uuid, boolean),
  admin_set_verified(uuid, boolean), admin_hide_review(uuid, boolean), admin_handle_report(uuid, text, text),
  admin_confirm_listing_paid(text, uuid, numeric, text), admin_dashboard() from public, anon;
grant  execute on function book_room(uuid, int, jsonb, text), book_apartment(uuid, jsonb, text), book_bus(uuid, int, jsonb, text),
  cancel_booking(uuid), owner_decide_booking(uuid, boolean), submit_review(text, uuid, int, text),
  adjust_outside(text, uuid, int), admin_review(text, uuid, boolean, text),
  admin_set_listing_paused(text, uuid, boolean), admin_set_user_status(uuid, boolean),
  admin_set_verified(uuid, boolean), admin_hide_review(uuid, boolean), admin_handle_report(uuid, text, text),
  admin_confirm_listing_paid(text, uuid, numeric, text), admin_dashboard() to authenticated;

-- التخزين: صور الإعلانات عامة للقراءة، والوثائق خاصة
-- مسار الملف لازم يبدأ بمعرّف المستخدم: <user_id>/<ملف>
insert into storage.buckets (id, name, public) values
  ('listing-media', 'listing-media', true),
  ('verification-docs', 'verification-docs', false)
on conflict (id) do nothing;
create policy "media_read"  on storage.objects for select using (bucket_id = 'listing-media');
create policy "media_write" on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs_upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs_read"   on storage.objects for select to authenticated
  using (bucket_id = 'verification-docs' and (is_admin() or (storage.foldername(name))[1] = auth.uid()::text));

-- ---------- 12) بيانات أولية: المحافظات والولايات والكليات (من التطبيق التجريبي) ----------
insert into governorates (name) values
  ('محافظة مسقط'),
  ('محافظة ظفار'),
  ('محافظة مسندم'),
  ('محافظة البريمي'),
  ('محافظة الداخلية'),
  ('محافظة شمال الباطنة'),
  ('محافظة جنوب الباطنة'),
  ('محافظة شمال الشرقية'),
  ('محافظة جنوب الشرقية'),
  ('محافظة الظاهرة'),
  ('محافظة الوسطى');

insert into wilayats (governorate_id, name)
select g.id, v.name from (values
  ('محافظة مسقط','مسقط'),
  ('محافظة مسقط','مطرح'),
  ('محافظة مسقط','بوشر'),
  ('محافظة مسقط','السيب'),
  ('محافظة مسقط','العامرات'),
  ('محافظة مسقط','قريات'),
  ('محافظة ظفار','صلالة'),
  ('محافظة ظفار','طاقة'),
  ('محافظة ظفار','مرباط'),
  ('محافظة ظفار','سدح'),
  ('محافظة ظفار','ثمريت'),
  ('محافظة ظفار','مقشن'),
  ('محافظة ظفار','رخيوت'),
  ('محافظة ظفار','ضلكوت'),
  ('محافظة ظفار','شليم وجزر الحلانيات'),
  ('محافظة ظفار','المزيونة'),
  ('محافظة مسندم','خصب'),
  ('محافظة مسندم','بخا'),
  ('محافظة مسندم','دبا'),
  ('محافظة مسندم','مدحاء'),
  ('محافظة البريمي','البريمي'),
  ('محافظة البريمي','محضة'),
  ('محافظة البريمي','السنينة'),
  ('محافظة الداخلية','نزوى'),
  ('محافظة الداخلية','سمائل'),
  ('محافظة الداخلية','بهلاء'),
  ('محافظة الداخلية','أدم'),
  ('محافظة الداخلية','الحمراء'),
  ('محافظة الداخلية','منح'),
  ('محافظة الداخلية','إزكي'),
  ('محافظة الداخلية','بدبد'),
  ('محافظة شمال الباطنة','صحار'),
  ('محافظة شمال الباطنة','شناص'),
  ('محافظة شمال الباطنة','لوى'),
  ('محافظة شمال الباطنة','صحم'),
  ('محافظة شمال الباطنة','الخابورة'),
  ('محافظة شمال الباطنة','السويق'),
  ('محافظة جنوب الباطنة','الرستاق'),
  ('محافظة جنوب الباطنة','العوابي'),
  ('محافظة جنوب الباطنة','نخل'),
  ('محافظة جنوب الباطنة','وادي المعاول'),
  ('محافظة جنوب الباطنة','بركاء'),
  ('محافظة جنوب الباطنة','المصنعة'),
  ('محافظة شمال الشرقية','إبراء'),
  ('محافظة شمال الشرقية','المضيبي'),
  ('محافظة شمال الشرقية','بدية'),
  ('محافظة شمال الشرقية','القابل'),
  ('محافظة شمال الشرقية','وادي بني خالد'),
  ('محافظة شمال الشرقية','دماء والطائيين'),
  ('محافظة شمال الشرقية','سناو'),
  ('محافظة جنوب الشرقية','صور'),
  ('محافظة جنوب الشرقية','جعلان بني بو علي'),
  ('محافظة جنوب الشرقية','جعلان بني بو حسن'),
  ('محافظة جنوب الشرقية','الكامل والوافي'),
  ('محافظة جنوب الشرقية','مصيرة'),
  ('محافظة الظاهرة','عبري'),
  ('محافظة الظاهرة','ينقل'),
  ('محافظة الظاهرة','ضنك'),
  ('محافظة الوسطى','هيماء'),
  ('محافظة الوسطى','محوت'),
  ('محافظة الوسطى','الدقم'),
  ('محافظة الوسطى','الجازر')
) as v(gov, name) join governorates g on g.name = v.gov;

insert into colleges (governorate_id, name)
select g.id, v.name from (values
  ('محافظة مسقط','جامعة السلطان قابوس'),
  ('محافظة مسقط','جامعة التقنية والعلوم التطبيقية - مسقط'),
  ('محافظة مسقط','كلية مجان الجامعية'),
  ('محافظة مسقط','كلية البيان'),
  ('محافظة مسقط','الكلية الوطنية لتقنية السيارات'),
  ('محافظة مسقط','كلية عمان للعلوم الصحية'),
  ('محافظة مسقط','الكلية الحديثة للتجارة والعلوم'),
  ('محافظة مسقط','كلية الدراسات المصرفية والمالية'),
  ('محافظة مسقط','كلية مسقط'),
  ('محافظة مسقط','الكلية العالمية للهندسة والتكنولوجيا'),
  ('محافظة مسقط','كلية العلوم الشرعية (الخوير)'),
  ('محافظة مسقط','كلية الشرق الأوسط'),
  ('محافظة مسقط','كلية الخليج'),
  ('محافظة مسقط','كلية مزون'),
  ('محافظة مسقط','الكلية الدولية للهندسة والإدارة (ICEM)'),
  ('محافظة مسقط','الكلية العلمية للتصميم'),
  ('محافظة مسقط','كلية عمان للسياحة'),
  ('محافظة مسقط','كلية الزهراء للبنات'),
  ('محافظة مسقط','الكلية المهنية - السيب'),
  ('محافظة البريمي','كلية البريمي الجامعية'),
  ('محافظة البريمي','الكلية المهنية - البريمي'),
  ('محافظة البريمي','كلية عمان للعلوم الصحية'),
  ('محافظة جنوب الشرقية','كلية صور الجامعية'),
  ('محافظة جنوب الشرقية','جامعة التقنية والعلوم التطبيقية - صور'),
  ('محافظة جنوب الشرقية','الكلية المهنية - صور'),
  ('محافظة جنوب الشرقية','كلية عمان للعلوم الصحية'),
  ('محافظة جنوب الباطنة','كلية عمان للإدارة والتكنولوجيا'),
  ('محافظة جنوب الباطنة','جامعة التقنية والعلوم التطبيقية - المصنعة'),
  ('محافظة جنوب الباطنة','جامعة التقنية والعلوم التطبيقية - الرستاق'),
  ('محافظة شمال الباطنة','جامعة صحار'),
  ('محافظة شمال الباطنة','جامعة التقنية والعلوم التطبيقية - صحار'),
  ('محافظة شمال الباطنة','جامعة التقنية والعلوم التطبيقية - شناص'),
  ('محافظة شمال الباطنة','أكاديمية عمان للطيران'),
  ('محافظة شمال الباطنة','الكلية المهنية - صحم'),
  ('محافظة شمال الباطنة','الكلية المهنية - شناص'),
  ('محافظة شمال الباطنة','الكلية المهنية - الخابورة'),
  ('محافظة شمال الباطنة','كلية عمان للعلوم الصحية'),
  ('محافظة الداخلية','جامعة نزوى'),
  ('محافظة الداخلية','جامعة التقنية والعلوم التطبيقية - نزوى'),
  ('محافظة الداخلية','كلية عمان للعلوم الصحية'),
  ('محافظة ظفار','جامعة ظفار'),
  ('محافظة ظفار','جامعة التقنية والعلوم التطبيقية - صلالة'),
  ('محافظة ظفار','الكلية المهنية - صلالة'),
  ('محافظة ظفار','كلية عمان للعلوم الصحية'),
  ('محافظة الظاهرة','جامعة التقنية والعلوم التطبيقية - عبري'),
  ('محافظة الظاهرة','الكلية المهنية - عبري'),
  ('محافظة شمال الشرقية','جامعة التقنية والعلوم التطبيقية - إبراء'),
  ('محافظة مسندم','جامعة التقنية والعلوم التطبيقية - مسندم')
) as v(gov, name) join governorates g on g.name = v.gov;

-- ---------- 13) المهام المجدولة (بعد تفعيل pg_cron من Database > Extensions) ----------
select cron.schedule('expire-bookings', '*/15 * * * *', $$select expire_pending_bookings()$$);
select cron.schedule('expire-listings', '0 3 * * *', $$select expire_listings()$$);
