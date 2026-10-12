-- FORT AVES - Abatedouro | Embalagens: cada cooperado envia as suas; o sistema controla o estoque
-- por cooperado, com entradas (recebimento) e saídas (baixa por lote produzido).

create table embalagens (
  id             bigint generated always as identity primary key,
  cooperado_id   bigint not null references cooperados,
  nome           text not null,
  estoque_minimo integer check (estoque_minimo >= 0),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  unique (cooperado_id, nome)
);

create table embalagem_movimentos (
  id           bigint generated always as identity primary key,
  embalagem_id bigint not null references embalagens,
  tipo         text not null check (tipo in ('entrada', 'saida')),
  quantidade   integer not null check (quantidade > 0),
  data         date not null default current_date,
  lote_id      bigint references lotes on delete cascade,   -- saída por lote; excluir o lote devolve o estoque
  observacao   text,
  criado_em    timestamptz not null default now(),
  criado_por   text default lower(auth.jwt() ->> 'email'),
  check (tipo = 'saida' or lote_id is null)
);
create index on embalagem_movimentos (embalagem_id);
create index on embalagem_movimentos (lote_id);

create view v_embalagem_saldo with (security_invoker = true) as
select e.id as embalagem_id, e.cooperado_id, e.nome, e.estoque_minimo, e.ativo,
       coalesce(sum(m.quantidade) filter (where m.tipo = 'entrada'), 0) as entradas,
       coalesce(sum(m.quantidade) filter (where m.tipo = 'saida'), 0)   as saidas,
       coalesce(sum(case m.tipo when 'entrada' then m.quantidade when 'saida' then -m.quantidade end), 0) as saldo
from embalagens e
left join embalagem_movimentos m on m.embalagem_id = e.id
group by e.id;

alter table embalagens enable row level security;
alter table embalagem_movimentos enable row level security;
create policy autorizados_all on embalagens for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());
create policy autorizados_all on embalagem_movimentos for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());
