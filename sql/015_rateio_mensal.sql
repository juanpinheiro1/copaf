-- COPAF - Abatedouro | Rateio mensal pelo custo real (definido em 06/11/2026).
--   No dia de produção ficam só os diaristas. Energia, água, limpeza e todos os demais gastos vão para Despesas.
--   Cada despesa tem um mês de referência e pode ser rateada em vários meses.
--   Custo de cada lote = diaristas do dia (pelas cabeças do dia)
--                      + rateio do mês × cabeças pagantes do lote,
--   rateio do mês = (equipe fixa + despesas do mês) ÷ cabeças pagantes do mês.
--   O custo é recalculado a partir dos lançamentos; o fechamento do mês grava o custo final de cada lote.
--   Substitui a taxa de estrutura (011): o mês se paga sozinho, sem diferença levada ao mês seguinte.
-- Transição: outubro/2026 é reaberto e recalculado; os custos lançados nos dias viram despesas.

begin;

-- ───────── 1. Reabre outubro e desfaz a taxa de novembro (o modelo antigo deixa de valer) ─────────
update competencias set fechada = false, est_mensalistas = null, est_despesas = null, est_energia_agua = null,
  est_real = null, est_arrecadado = null, est_cabecas = null, est_pendente = null
where competencia = '2026-10-01';
update competencias set taxa_estrutura = null, alvo_estrutura = 0 where competencia >= '2026-11-01';
update lotes set custo_fechado = null, custo_cabeca_fechado = null where data >= '2026-10-01';

-- ───────── 2. Despesas: mês de referência e rateio em vários meses ─────────
insert into despesa_categorias (nome) values ('Energia elétrica'), ('Água') on conflict (nome) do nothing;

alter table despesas
  add column competencia  date,
  add column meses_rateio smallint not null default 1 check (meses_rateio between 1 and 24);
update despesas set competencia = date_trunc('month', data::timestamp)::date;
alter table despesas alter column competencia set not null;

-- sem mês informado, vale o mês da data; sempre gravado como o 1º dia do mês
create or replace function despesas_competencia() returns trigger
language plpgsql set search_path = public as $$
begin
  new.competencia := date_trunc('month', coalesce(new.competencia, new.data)::timestamp)::date;
  return new;
end $$;
create trigger despesas_competencia before insert or update on despesas
  for each row execute function despesas_competencia();

-- mês fechado não aceita despesa que caia nele (mês de referência e meses do rateio)
create or replace function despesas_mes_aberto() returns trigger
language plpgsql set search_path = public as $$
declare m date;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select competencia into m from competencias
      where fechada and competencia between old.competencia and (old.competencia + make_interval(months => old.meses_rateio - 1))::date limit 1;
    if found then raise exception 'O mês % já foi fechado; esta despesa não pode mais ser alterada.', to_char(m, 'MM/YYYY'); end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    select competencia into m from competencias
      where fechada and competencia between new.competencia and (new.competencia + make_interval(months => new.meses_rateio - 1))::date limit 1;
    if found then raise exception 'O mês % já foi fechado; não aceita novas despesas.', to_char(m, 'MM/YYYY'); end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- ───────── 3. Custos lançados nos dias passam para Despesas ─────────
-- energia e água estimadas nos dias de outubro (decisão de 04/11: outubro fecha com a estimativa)
insert into despesas (data, competencia, categoria_id, descricao, valor, fonte)
select d.data, '2026-10-01', (select id from despesa_categorias where nome = 'Energia elétrica'),
       'Energia do dia de abate ' || to_char(d.data, 'DD/MM') || ' (estimativa ' || (d.energia_fim - d.energia_ini) || ' kWh, vinda do dia de produção)',
       round((d.energia_fim - d.energia_ini) * d.tarifa_energia, 2), 'outra'
from dias_producao d
where d.data >= '2026-10-01' and d.data < '2026-11-01' and (d.energia_fim - d.energia_ini) * d.tarifa_energia > 0;
insert into despesas (data, competencia, categoria_id, descricao, valor, fonte)
select d.data, '2026-10-01', (select id from despesa_categorias where nome = 'Água'),
       'Água do dia de abate ' || to_char(d.data, 'DD/MM') || ' (estimativa ' || (d.agua_fim - d.agua_ini) || ' m³, vinda do dia de produção)',
       round((d.agua_fim - d.agua_ini) * d.tarifa_agua, 2), 'outra'
from dias_producao d
where d.data >= '2026-10-01' and d.data < '2026-11-01' and (d.agua_fim - d.agua_ini) * d.tarifa_agua > 0;
-- a partir de novembro, energia e água entram pelas contas reais; a estimativa dos dias deixa de contar

-- limpeza e outros custos do dia (todos os dias)
insert into despesas (data, competencia, categoria_id, descricao, valor, fonte)
select c.data, date_trunc('month', c.data::timestamp)::date,
       (select id from despesa_categorias where nome = case
          when c.categoria = 'limpeza' then 'Produtos de limpeza'
          when c.descricao ~* 'almo|aliment|lanche|caf[eé]|janta' then 'Alimentação'
          when c.descricao ~* 'di[aá]ria' then 'Serviços de terceiros'
          else 'Outros' end),
       coalesce(nullif(trim(c.descricao), ''), 'Custo do dia') || ' (dia de abate ' || to_char(c.data, 'DD/MM') || ', vindo do dia de produção)',
       c.valor, 'outra'
from dia_custos c
where c.valor > 0;
-- os registros de dia_custos e as leituras dos medidores ficam guardados como histórico, mas não entram mais no custo

-- ───────── 4. Visões do custo ─────────
drop view if exists v_custo_lote;
drop view if exists v_custo_dia;

-- cada despesa repartida nos meses do rateio (a última parcela acerta os centavos)
create view v_despesa_mes with (security_invoker = true) as
select d.id as despesa_id, d.categoria_id, k.rateia, d.meses_rateio,
       (d.competencia + make_interval(months => g))::date as competencia,
       round(d.valor / d.meses_rateio, 2)
         + case when g = d.meses_rateio - 1 then d.valor - round(d.valor / d.meses_rateio, 2) * d.meses_rateio else 0 end as valor
from despesas d
join despesa_categorias k on k.id = d.categoria_id
cross join generate_series(0, d.meses_rateio - 1) g;

-- apuração do mês: diaristas, equipe fixa, despesas e cabeças
create view v_rateio_mes with (security_invoker = true) as
with meses as (
  select competencia from competencias
  union select date_trunc('month', data::timestamp)::date from lotes
  union select competencia from v_despesa_mes)
select m.competencia, coalesce(c.fechada, false) as fechada,
  coalesce(l.cabecas, 0)   as cabecas,
  coalesce(l.kg_vivo, 0)   as kg_vivo,
  coalesce(l.aves_com_peso, 0) as aves_com_peso,
  coalesce(dd.total, 0)    as diaristas,
  case when c.fechada and c.est_mensalistas is not null then c.est_mensalistas else coalesce(fx.total, 0) end as mensalistas,
  coalesce(dm.total, 0)    as despesas,
  case when c.fechada and c.est_mensalistas is not null then c.est_mensalistas else coalesce(fx.total, 0) end + coalesce(dm.total, 0) as rateio_total,
  round((case when c.fechada and c.est_mensalistas is not null then c.est_mensalistas else coalesce(fx.total, 0) end + coalesce(dm.total, 0))
        / nullif(l.cabecas, 0), 6) as rateio_cabeca
from meses m
left join competencias c on c.competencia = m.competencia
left join lateral (select sum(cabecas_pagantes) cabecas,
                          sum(peso_liquido_kg) filter (where peso_liquido_kg > 0) kg_vivo,
                          sum(cabecas_pagantes) filter (where peso_liquido_kg > 0) aves_com_peso
                   from lotes where date_trunc('month', data::timestamp)::date = m.competencia) l on true
left join lateral (select sum(valor) total from dia_diaristas where date_trunc('month', data::timestamp)::date = m.competencia) dd on true
left join lateral (select sum(valor) total from v_despesa_mes where rateia and competencia = m.competencia) dm on true
left join lateral (select sum(salario_mensal) total from funcionarios where vinculo = 'fixo' and ativo) fx on true;

-- custo do dia (mesmas colunas de antes: energia, água, limpeza e outros agora estão no rateio do mês)
create view v_custo_dia with (security_invoker = true) as
select x.data, x.competencia, x.custo_diaristas,
  0::numeric as custo_energia, 0::numeric as custo_agua, 0::numeric as custo_limpeza, 0::numeric as custo_outros,
  x.cabecas_dia,
  x.custo_diaristas as custo_direto,
  x.rateio_cabeca   as taxa_estrutura,
  round(coalesce(x.rateio_cabeca, 0) * x.cabecas_dia, 2) as custo_estrutura,
  x.custo_diaristas + round(coalesce(x.rateio_cabeca, 0) * x.cabecas_dia, 2) as custo_total
from (
  select d.data, d.competencia, r.rateio_cabeca,
    coalesce(dd.total, 0) as custo_diaristas,
    coalesce(l.cabecas, 0) as cabecas_dia
  from dias_producao d
  left join v_rateio_mes r on r.competencia = d.competencia
  left join lateral (select sum(valor) total from dia_diaristas where data = d.data) dd on true
  left join lateral (select sum(cabecas_pagantes) cabecas from lotes where data = d.data) l on true
) x;

create view v_custo_lote with (security_invoker = true) as
select l.id as lote_id, l.codigo, l.data, l.cooperado_id, l.cabecas_pagantes, l.peso_liquido_kg,
  round(cd.custo_diaristas * l.cabecas_pagantes / nullif(cd.cabecas_dia, 0), 2)  as custo_diaristas,
  round(coalesce(cd.taxa_estrutura, 0) * l.cabecas_pagantes, 2)                    as custo_rateio,
  round(cd.custo_diaristas * l.cabecas_pagantes / nullif(cd.cabecas_dia, 0), 2)
    + round(coalesce(cd.taxa_estrutura, 0) * l.cabecas_pagantes, 2)                as custo_lote,
  round(cd.custo_total / nullif(cd.cabecas_dia, 0), 4)                             as custo_por_cabeca
from lotes l
join v_custo_dia cd on cd.data = l.data;

grant select on v_despesa_mes, v_rateio_mes, v_custo_dia, v_custo_lote to authenticated;

-- ───────── 5. Fechar e reabrir o dia: agora é a conferência do dia (diaristas e lotes) ─────────
create or replace function fechar_dia(p_data date) returns void
language plpgsql set search_path = public as $$
declare d dias_producao; n integer; v_diar numeric; v_cab bigint;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  select * into d from dias_producao where data = p_data for update;
  if not found then raise exception 'O dia não está aberto.'; end if;
  if d.fechado then raise exception 'O dia já está fechado.'; end if;
  if exists (select 1 from competencias where competencia = d.competencia and fechada) then
    raise exception 'O mês deste dia já foi fechado.';
  end if;
  if not exists (select 1 from dia_diaristas where data = p_data) then
    raise exception 'Lance os diaristas do dia antes de fechar.';
  end if;
  select count(*) into n from lotes where data = p_data;
  if n = 0 then raise exception 'Não há lotes neste dia.'; end if;
  select count(*) into n from lotes where data = p_data and status <> 'finalizado';
  if n > 0 then raise exception 'Há % lote(s) ainda não finalizado(s).', n; end if;
  select coalesce(sum(valor), 0) into v_diar from dia_diaristas where data = p_data;
  select coalesce(sum(cabecas_pagantes), 0) into v_cab from lotes where data = p_data;
  if v_cab <= 0 then raise exception 'O dia não tem cabeças pagantes.'; end if;
  update dias_producao set fechado = true, fechado_em = now(), f_diaristas = v_diar, f_cabecas = v_cab,
    f_energia = null, f_agua = null, f_limpeza = null, f_outros = null, f_mensal = null, f_despesas = null, f_estrutura = null, f_total = null
  where data = p_data;
end $$;

create or replace function reabrir_dia(p_data date) returns void
language plpgsql set search_path = public as $$
begin
  if not usuario_admin() then raise exception 'Só o administrador pode reabrir um dia fechado.'; end if;
  if exists (select 1 from competencias where competencia = date_trunc('month', p_data::timestamp)::date and fechada) then
    raise exception 'O mês deste dia já foi fechado. Reabra o mês antes de reabrir o dia.';
  end if;
  update dias_producao set fechado = false, fechado_em = null, f_diaristas = null, f_energia = null, f_agua = null,
    f_limpeza = null, f_outros = null, f_mensal = null, f_despesas = null, f_estrutura = null, f_total = null, f_cabecas = null
  where data = p_data;
end $$;

-- ───────── 6. Fechar o mês: apura o rateio e grava o custo final de cada lote ─────────
create or replace function fechar_mes(p_comp date) returns jsonb
language plpgsql set search_path = public as $$
declare v_prox date := (p_comp + interval '1 month')::date; c competencias; n integer; r v_rateio_mes; ultimo bigint; dif numeric;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  insert into competencias (competencia) values (p_comp) on conflict do nothing;
  select * into c from competencias where competencia = p_comp for update;
  if c.fechada then raise exception 'Este mês já está fechado.'; end if;
  select count(*) into n from dias_producao where competencia = p_comp and not fechado;
  if n > 0 then raise exception 'Há % dia(s) de produção ainda aberto(s) neste mês. Feche-os antes de fechar o mês.', n; end if;
  select count(*) into n from lotes where data >= p_comp and data < v_prox;
  if n = 0 then raise exception 'Não há lotes neste mês.'; end if;

  -- grava a equipe fixa do fechamento (mudança posterior no cadastro não altera o mês fechado)
  update competencias set est_mensalistas = (select coalesce(sum(salario_mensal), 0) from funcionarios where vinculo = 'fixo' and ativo)
  where competencia = p_comp;
  update competencias set fechada = true where competencia = p_comp;
  select * into r from v_rateio_mes where competencia = p_comp;
  update competencias set est_despesas = r.despesas, est_real = r.rateio_total + r.diaristas, est_cabecas = r.cabecas,
    est_energia_agua = null, est_arrecadado = null, est_pendente = null
  where competencia = p_comp;

  -- custo final de cada dia e de cada lote
  update dias_producao d set f_diaristas = cd.custo_diaristas, f_cabecas = cd.cabecas_dia, f_estrutura = cd.custo_estrutura, f_total = cd.custo_total
  from v_custo_dia cd where cd.data = d.data and d.competencia = p_comp;
  update lotes l set custo_fechado = cl.custo_lote, custo_cabeca_fechado = round(cl.custo_lote / nullif(l.cabecas_pagantes, 0), 4)
  from v_custo_lote cl where cl.lote_id = l.id and l.data >= p_comp and l.data < v_prox;
  -- centavos do arredondamento ficam no último lote do mês
  select l.id into ultimo from lotes l where l.data >= p_comp and l.data < v_prox order by l.data desc, l.ordem desc limit 1;
  select (r.rateio_total + r.diaristas) - sum(custo_fechado) into dif from lotes where data >= p_comp and data < v_prox;
  update lotes set custo_fechado = custo_fechado + dif where id = ultimo and abs(dif) < 1;

  return jsonb_build_object('rateio_cabeca', r.rateio_cabeca, 'rateio_total', r.rateio_total, 'diaristas', r.diaristas,
    'mensalistas', r.mensalistas, 'despesas', r.despesas, 'cabecas', r.cabecas, 'custo_total', r.rateio_total + r.diaristas);
end $$;

create or replace function reabrir_mes(p_comp date) returns void
language plpgsql set search_path = public as $$
begin
  if not usuario_admin() then raise exception 'Só o administrador pode reabrir um mês fechado.'; end if;
  update competencias set fechada = false, est_mensalistas = null, est_despesas = null, est_energia_agua = null,
    est_real = null, est_arrecadado = null, est_cabecas = null, est_pendente = null
  where competencia = p_comp;
  update lotes set custo_fechado = null, custo_cabeca_fechado = null
  where data >= p_comp and data < (p_comp + interval '1 month')::date;
  update dias_producao set f_estrutura = null, f_total = null where competencia = p_comp;
end $$;

grant execute on function fechar_dia(date), reabrir_dia(date), fechar_mes(date), reabrir_mes(date) to authenticated;

commit;

-- Conferência: outubro recalculado no modelo novo (antes de fechar de novo)
select competencia, cabecas, diaristas, mensalistas, despesas, rateio_total, rateio_cabeca,
       round((diaristas + rateio_total) / nullif(cabecas, 0), 4) as custo_cabeca
from v_rateio_mes where competencia in ('2026-10-01', '2026-11-01') order by 1;
