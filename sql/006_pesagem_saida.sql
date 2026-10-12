-- FORT AVES - Abatedouro | Pesagem real de saída por produto e rendimento real para calibração.

create table lote_pesagens (
  id          bigint generated always as identity primary key,
  lote_id     bigint not null references lotes on delete cascade,
  produto     text not null references produtos,
  conservacao text not null default 'resfriado' check (conservacao in ('resfriado', 'congelado')),
  peso_kg     numeric(10,2) not null check (peso_kg > 0),
  volumes     integer check (volumes > 0),
  observacao  text,
  criado_em   timestamptz not null default now(),
  criado_por  text default lower(auth.jwt() ->> 'email')
);
create index on lote_pesagens (lote_id);
alter table lote_pesagens enable row level security;
create policy autorizados_all on lote_pesagens for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());

-- Aves destinadas a cada produto em cada lote, a partir das linhas do plano de cortes
create view v_plano_produtos with (security_invoker = true) as
select p.lote_id, x.produto, sum(p.aves) as aves
from lote_planos p
cross join lateral unnest(
  case when p.destino = 'inteiro' then array['inteiro_miudos']
  else array_remove(array[
         case p.peito when 'com_osso' then 'peito_osso' when 'file' then 'file_peito' end,
         case when p.peito = 'file' then 'sassami' end,
         case p.perna when 'junta' then 'coxa_sobrecoxa' when 'separada' then 'coxa' end,
         case when p.perna = 'separada' then 'sobrecoxa' end,
         case p.asa when 'completa' then 'asa_completa' when 'sem_ponta' then 'asa' when 'tulipa_meio' then 'coxinha_asa' end,
         case when p.asa = 'tulipa_meio' then 'meio_asa' end,
         case when p.dorso then 'dorso' end], null) || p.miudos
  end) as x(produto)
group by p.lote_id, x.produto;

-- Rendimento real médio por tipo de ave e produto: kg pesados ÷ kg vivos destinados ao produto,
-- somente lotes finalizados, com pesagem de entrada e com o produto no plano e pesado na saída.
create view v_rendimento_real with (security_invoker = true) as
select l.tipo_ave, pp.produto,
       count(*)                                                as lotes,
       sum(pp.aves * l.peso_liquido_kg / l.aves_recebidas)     as kg_vivo,
       sum(r.kg)                                               as kg_real,
       round(100 * sum(r.kg) / sum(pp.aves * l.peso_liquido_kg / l.aves_recebidas), 2) as pct_real
from v_plano_produtos pp
join lotes l on l.id = pp.lote_id and l.status = 'finalizado' and l.peso_liquido_kg > 0 and l.aves_recebidas > 0
join (select lote_id, produto, sum(peso_kg) as kg from lote_pesagens group by lote_id, produto) r
  on r.lote_id = pp.lote_id and r.produto = pp.produto
group by l.tipo_ave, pp.produto;
