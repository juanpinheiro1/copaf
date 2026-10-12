-- FORT AVES - Abatedouro | Câmara fria e expedição.
-- O que é pesado na saída da produção entra na câmara; a retirada pelo cooperado dá baixa.
-- Saldo por lote, produto e conservação.

create table expedicoes (
  id           bigint generated always as identity primary key,
  cooperado_id bigint not null references cooperados,
  data         date not null,
  retirado_por text,
  documento    text,
  placa        text,
  observacao   text,
  criado_em    timestamptz not null default now(),
  criado_por   text default lower(auth.jwt() ->> 'email')
);
create index on expedicoes (cooperado_id, data);

create table expedicao_itens (
  id           bigint generated always as identity primary key,
  expedicao_id bigint not null references expedicoes on delete cascade,
  lote_id      bigint not null references lotes,
  produto      text not null references produtos,
  conservacao  text not null check (conservacao in ('resfriado', 'congelado')),
  peso_kg      numeric(10,2) not null check (peso_kg > 0),
  volumes      integer check (volumes > 0)
);
create index on expedicao_itens (expedicao_id);
create index on expedicao_itens (lote_id);

alter table expedicoes enable row level security;
alter table expedicao_itens enable row level security;
create policy autorizados_all on expedicoes for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());
create policy autorizados_all on expedicao_itens for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());

create view v_camara_saldo with (security_invoker = true) as
select l.id as lote_id, l.codigo, l.data as data_abate, l.cooperado_id, l.tipo_ave, x.produto, x.conservacao,
       sum(x.kg_in)  as kg_entrada, sum(x.vol_in)  as vol_entrada,
       sum(x.kg_out) as kg_retirado, sum(x.vol_out) as vol_retirado,
       sum(x.kg_in) - sum(x.kg_out)   as saldo_kg,
       sum(x.vol_in) - sum(x.vol_out) as saldo_vol
from (
  select lote_id, produto, conservacao, peso_kg as kg_in, coalesce(volumes, 0) as vol_in, 0::numeric as kg_out, 0 as vol_out from lote_pesagens
  union all
  select lote_id, produto, conservacao, 0, 0, peso_kg, coalesce(volumes, 0) from expedicao_itens
) x
join lotes l on l.id = x.lote_id
group by l.id, x.produto, x.conservacao;

-- Registra a retirada inteira de uma vez e confere o saldo de cada item
create function registrar_retirada(p_cooperado bigint, p_data date, p_retirado_por text, p_documento text,
                                   p_placa text, p_observacao text, p_itens jsonb) returns bigint
language plpgsql set search_path = public as $$
declare v_id bigint; it jsonb; v_saldo numeric;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  if p_itens is null or jsonb_array_length(p_itens) = 0 then raise exception 'Inclua ao menos um item na retirada.'; end if;
  insert into expedicoes (cooperado_id, data, retirado_por, documento, placa, observacao)
    values (p_cooperado, p_data, nullif(trim(p_retirado_por), ''), nullif(trim(p_documento), ''), nullif(trim(p_placa), ''), nullif(trim(p_observacao), ''))
    returning id into v_id;
  for it in select * from jsonb_array_elements(p_itens) loop
    select saldo_kg into v_saldo from v_camara_saldo
      where lote_id = (it ->> 'lote_id')::bigint and produto = it ->> 'produto'
        and conservacao = it ->> 'conservacao' and cooperado_id = p_cooperado;
    if v_saldo is null or (it ->> 'peso_kg')::numeric > v_saldo + 0.005 then
      raise exception 'Saldo insuficiente na câmara para % (lote %).',
        (select nome from produtos where codigo = it ->> 'produto'),
        (select codigo from lotes where id = (it ->> 'lote_id')::bigint);
    end if;
    insert into expedicao_itens (expedicao_id, lote_id, produto, conservacao, peso_kg, volumes)
      values (v_id, (it ->> 'lote_id')::bigint, it ->> 'produto', it ->> 'conservacao',
              (it ->> 'peso_kg')::numeric, nullif(it ->> 'volumes', '')::integer);
  end loop;
  return v_id;
end $$;
revoke execute on function registrar_retirada(bigint, date, text, text, text, text, jsonb) from public, anon;
grant execute on function registrar_retirada(bigint, date, text, text, text, text, jsonb) to authenticated;
