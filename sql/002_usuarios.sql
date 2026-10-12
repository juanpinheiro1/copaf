-- FORT AVES - Abatedouro | Usuários autorizados (mesmo modelo da Mesa Insiel)
-- O administrador autoriza um e-mail; a pessoa cria a própria senha em "Primeiro acesso".
-- Só e-mails autorizados e ativos enxergam ou alteram qualquer dado.

create table usuarios (
  email     text primary key check (email = lower(email)),
  nome      text,
  papel     text not null default 'operador' check (papel in ('admin', 'operador')),
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);
insert into usuarios (email, nome, papel) values ('juanpinheiro1@gmail.com', 'Juan Pinheiro', 'admin');

create function usuario_autorizado() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from usuarios where email = lower(auth.jwt() ->> 'email') and ativo) $$;

create function usuario_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from usuarios where email = lower(auth.jwt() ->> 'email') and ativo and papel = 'admin') $$;

-- Usada pela tela logo após o login: devolve o cadastro de quem está logado (ou nada)
create function minha_autorizacao() returns usuarios
language sql stable security definer set search_path = public as
$$ select * from usuarios where email = lower(auth.jwt() ->> 'email') and ativo $$;

revoke execute on function usuario_autorizado(), usuario_admin(), minha_autorizacao() from public, anon;
grant execute on function usuario_autorizado(), usuario_admin(), minha_autorizacao() to authenticated;

alter table usuarios enable row level security;
create policy usuarios_ler on usuarios for select to authenticated using (usuario_autorizado());
create policy usuarios_admin on usuarios for all to authenticated using (usuario_admin()) with check (usuario_admin());

-- Troca a regra "qualquer autenticado" pela lista de autorizados
do $$
declare t text;
begin
  foreach t in array array['cooperados','motoristas','veiculos','tipos_ave','funcionarios','competencias',
                           'custos_mensais','dias_producao','dia_diaristas','dia_custos','lotes']
  loop
    execute format('drop policy escritorio_all on %I', t);
    execute format('create policy autorizados_all on %I for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado())', t);
  end loop;
end $$;
