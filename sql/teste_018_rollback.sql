-- Teste da 018 com rollback (17/11/2026)
begin;

-- ───────── 1. Galinha Caipira ─────────
insert into tipos_ave (codigo, nome) values ('GC', 'Galinha Caipira');
insert into rendimentos (tipo_ave, produto, pct) select 'GC', produto, pct from rendimentos where tipo_ave = 'FC';
update produtos set ordem = ordem + 1 where ordem >= 10;
insert into produtos (codigo, nome, ordem) values ('galinha_caipira', 'GALINHA CAIPIRA', 10);

-- ───────── 2. Permissão de caixa ─────────
alter table usuarios add column caixa_liberado boolean not null default false;
update usuarios set caixa_liberado = true where email = 'fariasgilmar438@gmail.com';

create function usuario_caixa() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from usuarios where email = lower(auth.jwt() ->> 'email') and ativo and caixa_liberado) $$;
revoke execute on function usuario_caixa() from public, anon;
grant execute on function usuario_caixa() to authenticated;

-- ajustes de caixa: sobra (entra) e falta (sai)
alter table caixa_movimentos drop constraint caixa_movimentos_tipo_check;
alter table caixa_movimentos add constraint caixa_movimentos_tipo_check check (tipo in ('aporte', 'devolucao', 'sobra', 'falta'));

-- ───────── 3. Fechamentos ─────────
create table caixa_fechamentos (
  data           date primary key,                 -- dia fechado
  desde          date,                             -- primeiro dia coberto (null = abertura do controle, todo o histórico)
  saldo_inicial  numeric(12,2) not null,
  aportes        numeric(12,2) not null,
  despesas       numeric(12,2) not null,           -- despesas pagas pelo caixa
  devolucoes     numeric(12,2) not null,
  ajustes        numeric(12,2) not null,           -- sobras − faltas lançadas no período (sem a diferença do fechamento)
  saldo_sistema  numeric(12,2) not null,           -- saldo calculado antes da conferência
  contado        numeric(12,2) not null check (contado >= 0),
  diferenca      numeric(12,2) generated always as (contado - saldo_sistema) stored,
  saldo_final    numeric(12,2) generated always as (contado) stored,
  observacao     text,
  fechado_por    text not null default lower(auth.jwt() ->> 'email'),
  fechado_em     timestamptz not null default now()
);
alter table caixa_fechamentos enable row level security;
create policy autorizados_ler on caixa_fechamentos for select to authenticated using (usuario_autorizado());
grant select on caixa_fechamentos to authenticated;
-- sem insert/update/delete para usuários: só pela função fechar_caixa (e nunca se apaga)

create function caixa_fechado_ate() returns date
language sql stable security definer set search_path = public as $$ select max(data) from caixa_fechamentos $$;
grant execute on function caixa_fechado_ate() to authenticated;

-- trava dos aportes, devoluções e ajustes
create function caixa_movimentos_trava() returns trigger
language plpgsql set search_path = public as $$
declare f date := caixa_fechado_ate();
begin
  if current_setting('copaf.fechando_caixa', true) = 'sim' then return coalesce(new, old); end if;
  if tg_op in ('UPDATE', 'DELETE') then
    if old.data <= f then raise exception 'O caixa do dia % já foi fechado; este lançamento não pode mais ser alterado. Faça um ajuste num dia aberto.', to_char(old.data, 'DD/MM/YYYY'); end if;
    if not usuario_caixa() then raise exception 'Só os usuários liberados para o caixa podem alterar ou excluir lançamentos do caixa.'; end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.data <= f then
    raise exception 'O caixa já está fechado até %; lance com data posterior.', to_char(f, 'DD/MM/YYYY'); end if;
  return coalesce(new, old);
end $$;
create trigger caixa_movimentos_trava before insert or update or delete on caixa_movimentos
  for each row execute function caixa_movimentos_trava();

-- trava das despesas pagas pelo caixa
create function despesas_caixa_trava() returns trigger
language plpgsql set search_path = public as $$
declare f date := caixa_fechado_ate();
begin
  if tg_op in ('UPDATE', 'DELETE') and old.fonte = 'caixa' then
    if old.data <= f then raise exception 'O caixa do dia % já foi fechado; esta despesa paga pelo caixa não pode mais ser alterada. Faça um ajuste num dia aberto.', to_char(old.data, 'DD/MM/YYYY'); end if;
    if not usuario_caixa() then raise exception 'Só os usuários liberados para o caixa podem alterar ou excluir despesas pagas pelo caixa.'; end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.fonte = 'caixa' and new.data <= f then
    raise exception 'O caixa já está fechado até %; a despesa paga pelo caixa precisa ter data posterior.', to_char(f, 'DD/MM/YYYY'); end if;
  return coalesce(new, old);
end $$;
create trigger despesas_caixa_trava before insert or update or delete on despesas
  for each row execute function despesas_caixa_trava();

-- prévia do fechamento (a tela usa para mostrar o saldo antes de fechar)
create function caixa_previa(p_data date)
returns table (desde date, saldo_inicial numeric, aportes numeric, despesas numeric, devolucoes numeric, ajustes numeric, saldo_sistema numeric)
language plpgsql stable security definer set search_path = public as $$
declare f date := caixa_fechado_ate(); ini numeric := 0;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  if f is not null then select saldo_final into ini from caixa_fechamentos where data = f; end if;
  return query
    with mv as (select tipo, valor from caixa_movimentos where data <= p_data and (f is null or data > f)),
         dp as (select valor from despesas where fonte = 'caixa' and data <= p_data and (f is null or data > f))
    select case when f is null then null else f + 1 end, ini,
      coalesce((select sum(valor) from mv where tipo = 'aporte'), 0),
      coalesce((select sum(valor) from dp), 0),
      coalesce((select sum(valor) from mv where tipo = 'devolucao'), 0),
      coalesce((select sum(case tipo when 'sobra' then valor else -valor end) from mv where tipo in ('sobra', 'falta')), 0),
      ini + coalesce((select sum(case when tipo in ('aporte', 'sobra') then valor else -valor end) from mv), 0) - coalesce((select sum(valor) from dp), 0);
end $$;
revoke execute on function caixa_previa(date) from public, anon;
grant execute on function caixa_previa(date) to authenticated;

create function fechar_caixa(p_data date, p_contado numeric, p_obs text default null) returns caixa_fechamentos
language plpgsql security definer set search_path = public as $$
declare f date; p record; d date; r caixa_fechamentos;
begin
  if not usuario_caixa() then raise exception 'Só os usuários liberados para o caixa podem fechar o caixa.'; end if;
  perform pg_advisory_xact_lock(918018);
  f := caixa_fechado_ate();
  if p_data is null or p_contado is null or p_contado < 0 then raise exception 'Informe o dia e o dinheiro contado no caixa.'; end if;
  if p_data > (now() at time zone 'America/Fortaleza')::date then raise exception 'Não é possível fechar um dia futuro.'; end if;
  if f is not null and p_data <= f then raise exception 'O caixa já está fechado até %.', to_char(f, 'DD/MM/YYYY'); end if;
  if f is not null then
    select min(x.data) into d from (
      select data from caixa_movimentos where data > f and data < p_data
      union all select data from despesas where fonte = 'caixa' and data > f and data < p_data) x;
    if d is not null then raise exception 'Feche primeiro o caixa do dia %, que tem movimento.', to_char(d, 'DD/MM/YYYY'); end if;
  end if;
  select * into p from caixa_previa(p_data);
  insert into caixa_fechamentos (data, desde, saldo_inicial, aportes, despesas, devolucoes, ajustes, saldo_sistema, contado, observacao)
    values (p_data, p.desde, p.saldo_inicial, p.aportes, p.despesas, p.devolucoes, p.ajustes, p.saldo_sistema, round(p_contado, 2), nullif(trim(p_obs), ''))
    returning * into r;
  if r.diferenca <> 0 then
    perform set_config('copaf.fechando_caixa', 'sim', true);
    insert into caixa_movimentos (data, tipo, valor, descricao)
      values (p_data, case when r.diferenca > 0 then 'sobra' else 'falta' end, abs(r.diferenca), 'Diferença na conferência do fechamento do caixa');
    perform set_config('copaf.fechando_caixa', '', true);
  end if;
  return r;
end $$;
revoke execute on function fechar_caixa(date, numeric, text) from public, anon;
grant execute on function fechar_caixa(date, numeric, text) to authenticated;


-- ───── testes ─────
update usuarios set caixa_liberado = true where email = 'juanpinheiro1@gmail.com';
select set_config('request.jwt.claims', '{"email":"juanpinheiro1@gmail.com"}', true);
do $$
declare h date := (now() at time zone 'America/Fortaleza')::date; r caixa_fechamentos; p record; ok boolean; s0 numeric; s1 numeric; msg text := '';
begin
  -- 1) abertura: fecha ontem conferindo o saldo do sistema
  select * into p from caixa_previa(h - 1); s0 := p.saldo_sistema;
  r := fechar_caixa(h - 1, s0, 'teste abertura');
  if r.diferenca <> 0 or r.saldo_final <> s0 or r.desde is not null then raise exception 'falha 1'; end if;
  msg := msg || format('abertura saldo %s; ', s0);
  -- 2) lançar em dia fechado é recusado
  ok := false; begin insert into caixa_movimentos (data, tipo, valor) values (h - 1, 'aporte', 10); exception when others then ok := true; end;
  if not ok then raise exception 'falha 2a'; end if;
  ok := false; begin insert into despesas (data, categoria_id, descricao, valor, fonte) values (h - 1, (select min(id) from despesa_categorias), 't', 5, 'caixa'); exception when others then ok := true; end;
  if not ok then raise exception 'falha 2b'; end if;
  -- despesa de outra fonte em dia fechado continua aceita
  insert into despesas (data, categoria_id, descricao, valor, fonte) values (h - 1, (select min(id) from despesa_categorias), 't outra', 5, 'outra');
  -- alterar algo antigo é recusado
  ok := false; begin update caixa_movimentos set valor = valor where data <= h - 1; if not found then ok := true; end if; exception when others then ok := true; end;
  if not ok then raise exception 'falha 2c'; end if;
  -- 3) movimento hoje e fechamento com falta de 10
  select saldo_sistema into s1 from caixa_previa(h);
  insert into caixa_movimentos (data, tipo, valor) values (h, 'aporte', 100);
  insert into despesas (data, categoria_id, descricao, valor, fonte) values (h, (select min(id) from despesa_categorias), 't', 30, 'caixa');
  select * into p from caixa_previa(h);
  if p.saldo_inicial <> s0 or p.saldo_sistema <> s1 + 70 or p.desde <> h then raise exception 'falha 3a %', p; end if;
  r := fechar_caixa(h, s1 + 60);
  if r.diferenca <> -10 or r.saldo_final <> s1 + 60 then raise exception 'falha 3b'; end if;
  if not exists (select 1 from caixa_movimentos where data = h and tipo = 'falta' and valor = 10) then raise exception 'falha 3c'; end if;
  -- saldo calculado do zero bate com o saldo final
  if (select coalesce(sum(case when tipo in ('aporte','sobra') then valor else -valor end),0) from caixa_movimentos)
     - (select coalesce(sum(valor),0) from despesas where fonte = 'caixa') <> s1 + 60 then raise exception 'falha 3d'; end if;
  -- 4) dia futuro não fecha; fechar de novo não fecha
  ok := false; begin r := fechar_caixa(h + 1, 0); exception when others then ok := true; end; if not ok then raise exception 'falha 4a'; end if;
  ok := false; begin r := fechar_caixa(h, 0); exception when others then ok := true; end; if not ok then raise exception 'falha 4b'; end if;
  -- 5) não liberado: lança, mas não altera nem exclui
  insert into caixa_movimentos (data, tipo, valor) values (h + 1, 'aporte', 1);
  perform set_config('request.jwt.claims', '{"email":"ninguem@teste.com"}', true);
  insert into caixa_movimentos (data, tipo, valor) values (h + 1, 'aporte', 2);
  ok := false; begin update caixa_movimentos set valor = 3 where data = h + 1; exception when others then ok := true; end; if not ok then raise exception 'falha 5a'; end if;
  ok := false; begin delete from caixa_movimentos where data = h + 1; exception when others then ok := true; end; if not ok then raise exception 'falha 5b'; end if;
  ok := false; begin r := fechar_caixa(h, 0); exception when others then ok := true; end; if not ok then raise exception 'falha 5c'; end if;
  perform set_config('request.jwt.claims', '{"email":"juanpinheiro1@gmail.com"}', true);
  delete from caixa_movimentos where data = h + 1;
  msg := msg || format('hoje antes %s; ', s1) || format('GC rendimentos %s; produto ordem %s', (select count(*) from rendimentos where tipo_ave = 'GC'), (select ordem from produtos where codigo = 'galinha_caipira'));
  raise exception 'TESTE OK (desfeito): %', msg;
end $$;
