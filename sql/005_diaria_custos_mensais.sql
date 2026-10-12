-- FORT AVES - Abatedouro | Regra da diária dos custos mensais (definida em 12/10/2026):
-- soma de todos os custos mensais (mensalistas do cadastro de equipe + demais custos mensais do mês)
-- dividida por 15. O divisor fica em competencias.dias_abate_previstos (padrão 15) e pode ser ajustado.
-- A diária entra no custo de cada dia de produção e é rateada pelas cabeças do dia.
-- Não há mais acerto de custos fixos no complemento mensal.

alter table competencias alter column dias_abate_previstos set default 15;
update competencias set dias_abate_previstos = 15 where dias_abate_previstos is null;

create or replace view v_custo_dia with (security_invoker = true) as
select
  d.data,
  d.competencia,
  coalesce(dd.total, 0)                                              as custo_diaristas,
  coalesce((d.energia_fim - d.energia_ini) * d.tarifa_energia, 0)    as custo_energia,
  coalesce((d.agua_fim - d.agua_ini) * d.tarifa_agua, 0)             as custo_agua,
  coalesce(dc.limpeza, 0)                                            as custo_limpeza,
  coalesce(dc.outros, 0)                                             as custo_outros,
  (coalesce(cm.previsto, 0) + coalesce(fx.total, 0)) / coalesce(c.dias_abate_previstos, 15) as parcela_custos_mensais,
  coalesce(l.cabecas, 0)                                             as cabecas_dia,
  coalesce(dd.total, 0)
    + coalesce((d.energia_fim - d.energia_ini) * d.tarifa_energia, 0)
    + coalesce((d.agua_fim - d.agua_ini) * d.tarifa_agua, 0)
    + coalesce(dc.limpeza, 0) + coalesce(dc.outros, 0)
    + (coalesce(cm.previsto, 0) + coalesce(fx.total, 0)) / coalesce(c.dias_abate_previstos, 15) as custo_total
from dias_producao d
left join competencias c on c.competencia = d.competencia
left join lateral (select sum(valor) total from dia_diaristas where data = d.data) dd on true
left join lateral (
  select sum(valor) filter (where categoria = 'limpeza') limpeza,
         sum(valor) filter (where categoria = 'outros')  outros
  from dia_custos where data = d.data) dc on true
left join lateral (select sum(valor_previsto) previsto from custos_mensais where competencia = d.competencia) cm on true
left join lateral (select sum(salario_mensal) total from funcionarios where vinculo = 'fixo' and ativo) fx on true
left join lateral (select sum(cabecas_pagantes) cabecas from lotes where data = d.data) l on true;

create or replace view v_complemento_mes with (security_invoker = true) as
select
  c.competencia,
  c.energia_conta_valor - coalesce(d.energia_cobrada, 0) as complemento_energia,
  c.agua_conta_valor    - coalesce(d.agua_cobrada, 0)    as complemento_agua,
  d.cabecas_mes,
  0::numeric                                             as complemento_fixos
from competencias c
left join lateral (
  select sum(coalesce(dp.f_energia, v.custo_energia)) energia_cobrada,
         sum(coalesce(dp.f_agua, v.custo_agua))       agua_cobrada,
         sum(v.cabecas_dia)                           cabecas_mes
  from v_custo_dia v join dias_producao dp on dp.data = v.data
  where v.competencia = c.competencia) d on true;
