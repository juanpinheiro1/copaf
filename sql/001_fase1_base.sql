-- FORT AVES - Abatedouro | Fase 1: cadastros, recebimento, dia de produção e custo por lote
-- Regras (aceitas em 11/10/2026):
--   * rateio por cabeça abatida; galeto paga o mesmo que frango grande
--   * mortos na chegada e condenadas pelo SIE não pagam
--   * lote sem pesagem: cobra-se pela contagem de carcaças na expedição
--   * custo do lote fecha no dia; custos mensais entram por diária (previsto / dias de abate previstos)
--   * energia e água: no dia, consumo medido x tarifa de referência; no fim do mês lança-se a conta real
--     e a diferença (consumo fora de produção + diferença de tarifa) é rateada pelas cabeças do mês

-- ───────────── Cadastros ─────────────
create table cooperados (
  id         bigint generated always as identity primary key,
  nome       text not null,
  documento  text,
  telefone   text,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

create table motoristas (
  id    bigint generated always as identity primary key,
  nome  text not null,
  ativo boolean not null default true
);

create table veiculos (
  id        bigint generated always as identity primary key,
  placa     text not null unique,
  descricao text,
  tara_kg   numeric(10,2),
  ativo     boolean not null default true
);

create table tipos_ave (
  codigo text primary key,
  nome   text not null
);
insert into tipos_ave (codigo, nome) values
  ('FC', 'Frango Caipira'),
  ('FG', 'Frango Grande'),
  ('GL', 'Galetinho');

create table funcionarios (
  id             bigint generated always as identity primary key,
  nome           text not null,
  vinculo        text not null check (vinculo in ('fixo', 'diarista')),
  funcao         text,
  valor_diaria   numeric(10,2),   -- diarista: valor padrão sugerido no dia
  salario_mensal numeric(10,2),   -- fixo: custo mensal total (salário + encargos)
  ativo          boolean not null default true
);

-- ───────────── Competência (mês) ─────────────
create table competencias (
  competencia           date primary key check (extract(day from competencia) = 1),
  dias_abate_previstos  integer not null check (dias_abate_previstos > 0),
  energia_conta_kwh     numeric(12,2),
  energia_conta_valor   numeric(12,2),
  agua_conta_m3         numeric(12,2),
  agua_conta_valor      numeric(12,2),
  fechada               boolean not null default false
);

create table custos_mensais (
  id             bigint generated always as identity primary key,
  competencia    date not null references competencias,
  categoria      text not null check (categoria in
                   ('salarios_fixos', 'manutencao', 'produtos_limpeza', 'ajuste_mes_anterior', 'outros')),
  descricao      text,
  valor_previsto numeric(12,2) not null,
  valor_real     numeric(12,2)
);
create index on custos_mensais (competencia);

-- ───────────── Dia de produção ─────────────
create table dias_producao (
  data           date primary key,
  competencia    date generated always as (date_trunc('month', data::timestamp)::date) stored references competencias,
  energia_ini    numeric(12,2),
  energia_fim    numeric(12,2),
  tarifa_energia numeric(10,6),   -- R$/kWh de referência (última conta real)
  agua_ini       numeric(12,3),
  agua_fim       numeric(12,3),
  tarifa_agua    numeric(10,6),   -- R$/m³ de referência (última conta real)
  observacao     text,
  fechado        boolean not null default false,
  fechado_em     timestamptz,
  check (energia_fim is null or energia_ini is null or energia_fim >= energia_ini),
  check (agua_fim is null or agua_ini is null or agua_fim >= agua_ini)
);

create table dia_diaristas (
  id             bigint generated always as identity primary key,
  data           date not null references dias_producao on delete cascade,
  funcionario_id bigint not null references funcionarios,
  funcao         text,
  valor          numeric(10,2) not null,
  unique (data, funcionario_id)
);

create table dia_custos (
  id        bigint generated always as identity primary key,
  data      date not null references dias_producao on delete cascade,
  categoria text not null check (categoria in ('limpeza', 'outros')),
  descricao text,
  valor     numeric(12,2) not null
);
create index on dia_custos (data);

-- ───────────── Lote (ficha de pendura) ─────────────
create table lotes (
  id                 bigint generated always as identity primary key,
  codigo             text not null unique,            -- ex.: 20261006-02
  data               date not null references dias_producao,
  ordem              integer not null,                -- sequência de abate no dia
  cooperado_id       bigint not null references cooperados,
  motorista_id       bigint references motoristas,
  veiculo_id         bigint references veiculos,
  tipo_ave           text not null references tipos_ave,
  peso_bruto_kg      numeric(10,2),
  tara_kg            numeric(10,2),
  qtd_caixas         integer,
  aves_por_caixa     integer,
  carcacas_contadas  integer,                         -- lote sem pesagem: contagem na expedição
  mortos_chegada     integer not null default 0,
  condenadas         integer not null default 0,
  velocidade_hz      numeric(6,2),
  hora_inicio        time,
  hora_termino       time,
  minutos_parada     integer not null default 0,
  observacao         text,
  criado_em          timestamptz not null default now(),
  peso_liquido_kg    numeric(10,2) generated always as (peso_bruto_kg - tara_kg) stored,
  aves_recebidas     integer generated always as (qtd_caixas * aves_por_caixa) stored,
  cabecas_pagantes   integer generated always as (
    coalesce(carcacas_contadas, qtd_caixas * aves_por_caixa - mortos_chegada - condenadas)
  ) stored,
  unique (data, ordem),
  check (carcacas_contadas is not null or (qtd_caixas is not null and aves_por_caixa is not null))
);
create index on lotes (cooperado_id, data);

-- ───────────── Apuração ─────────────
create view v_custo_dia with (security_invoker = true) as
select
  d.data,
  d.competencia,
  coalesce(dd.total, 0)                                              as custo_diaristas,
  coalesce((d.energia_fim - d.energia_ini) * d.tarifa_energia, 0)    as custo_energia,
  coalesce((d.agua_fim - d.agua_ini) * d.tarifa_agua, 0)             as custo_agua,
  coalesce(dc.limpeza, 0)                                            as custo_limpeza,
  coalesce(dc.outros, 0)                                             as custo_outros,
  coalesce(cm.previsto / c.dias_abate_previstos, 0)                  as parcela_custos_mensais,
  coalesce(l.cabecas, 0)                                             as cabecas_dia,
  coalesce(dd.total, 0)
    + coalesce((d.energia_fim - d.energia_ini) * d.tarifa_energia, 0)
    + coalesce((d.agua_fim - d.agua_ini) * d.tarifa_agua, 0)
    + coalesce(dc.limpeza, 0) + coalesce(dc.outros, 0)
    + coalesce(cm.previsto / c.dias_abate_previstos, 0)              as custo_total
from dias_producao d
left join competencias c on c.competencia = d.competencia
left join lateral (select sum(valor) total from dia_diaristas where data = d.data) dd on true
left join lateral (
  select sum(valor) filter (where categoria = 'limpeza') limpeza,
         sum(valor) filter (where categoria = 'outros')  outros
  from dia_custos where data = d.data) dc on true
left join lateral (select sum(valor_previsto) previsto from custos_mensais where competencia = d.competencia) cm on true
left join lateral (select sum(cabecas_pagantes) cabecas from lotes where data = d.data) l on true;

create view v_custo_lote with (security_invoker = true) as
select
  l.id as lote_id, l.codigo, l.data, l.cooperado_id, l.cabecas_pagantes,
  round(cd.custo_total / nullif(cd.cabecas_dia, 0), 4)                        as custo_por_cabeca,
  round(cd.custo_total * l.cabecas_pagantes / nullif(cd.cabecas_dia, 0), 2)   as custo_lote
from lotes l
join v_custo_dia cd on cd.data = l.data;

-- Complemento mensal: conta real de energia/água menos o que já foi cobrado nos dias
create view v_complemento_mes with (security_invoker = true) as
select
  c.competencia,
  c.energia_conta_valor - coalesce(d.energia_cobrada, 0) as complemento_energia,
  c.agua_conta_valor    - coalesce(d.agua_cobrada, 0)    as complemento_agua,
  d.cabecas_mes
from competencias c
left join lateral (
  select sum(custo_energia) energia_cobrada, sum(custo_agua) agua_cobrada, sum(cabecas_dia) cabecas_mes
  from v_custo_dia where competencia = c.competencia) d on true;

create view v_complemento_cooperado with (security_invoker = true) as
select
  m.competencia, l.cooperado_id,
  sum(l.cabecas_pagantes) as cabecas,
  round((coalesce(m.complemento_energia, 0) + coalesce(m.complemento_agua, 0))
        * sum(l.cabecas_pagantes) / nullif(m.cabecas_mes, 0), 2) as complemento
from v_complemento_mes m
join dias_producao d on d.competencia = m.competencia
join lotes l on l.data = d.data
group by m.competencia, l.cooperado_id, m.complemento_energia, m.complemento_agua, m.cabecas_mes;

-- ───────────── Segurança: só usuários autenticados (escritório) ─────────────
do $$
declare t text;
begin
  foreach t in array array['cooperados','motoristas','veiculos','tipos_ave','funcionarios','competencias',
                           'custos_mensais','dias_producao','dia_diaristas','dia_custos','lotes']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy escritorio_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;
