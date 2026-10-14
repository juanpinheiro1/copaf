-- COPAF - Abatedouro | Rateio em duas parcelas (definido em 13/10/2026):
--   1) custo direto do dia: diaristas + energia e água medidas + limpeza/outros, pelas cabeças do dia;
--   2) taxa de estrutura por cabeça, fixa no mês: mensalistas + despesas + energia/água fora dos dias de abate.
-- A taxa de um mês sai do fechamento do mês anterior; o que sobra ou falta passa para o mês seguinte.
-- Substitui a diária ÷ 15, o complemento mensal de energia/água e a taxa de despesas.

drop view if exists v_complemento_cooperado;
drop view if exists v_complemento_mes;
drop view if exists v_custo_lote;
drop view if exists v_custo_dia;

alter table competencias
  add column taxa_estrutura  numeric(12,6),                    -- R$ por cabeça aplicado neste mês
  add column alvo_estrutura  numeric(14,2) not null default 0, -- quanto a taxa deste mês precisa recuperar
  add column est_mensalistas numeric(14,2),                    -- apuração gravada ao fechar o mês
  add column est_despesas    numeric(14,2),
  add column est_energia_agua numeric(14,2),
  add column est_real        numeric(14,2),
  add column est_arrecadado  numeric(14,2),
  add column est_cabecas     integer,
  add column est_pendente    numeric(14,2);
alter table dias_producao add column f_estrutura numeric(12,2);

create view v_custo_dia with (security_invoker = true) as
select
  x.data, x.competencia, x.custo_diaristas, x.custo_energia, x.custo_agua, x.custo_limpeza, x.custo_outros, x.cabecas_dia,
  x.custo_diaristas + x.custo_energia + x.custo_agua + x.custo_limpeza + x.custo_outros as custo_direto,
  x.taxa_estrutura,
  round(coalesce(x.taxa_estrutura, 0) * x.cabecas_dia, 2)                               as custo_estrutura,
  x.custo_diaristas + x.custo_energia + x.custo_agua + x.custo_limpeza + x.custo_outros
    + round(coalesce(x.taxa_estrutura, 0) * x.cabecas_dia, 2)                           as custo_total
from (
  select d.data, d.competencia, c.taxa_estrutura,
    coalesce(dd.total, 0)                                           as custo_diaristas,
    coalesce((d.energia_fim - d.energia_ini) * d.tarifa_energia, 0) as custo_energia,
    coalesce((d.agua_fim - d.agua_ini) * d.tarifa_agua, 0)          as custo_agua,
    coalesce(dc.limpeza, 0)                                         as custo_limpeza,
    coalesce(dc.outros, 0)                                          as custo_outros,
    coalesce(l.cabecas, 0)                                          as cabecas_dia
  from dias_producao d
  left join competencias c on c.competencia = d.competencia
  left join lateral (select sum(valor) total from dia_diaristas where data = d.data) dd on true
  left join lateral (
    select sum(valor) filter (where categoria = 'limpeza') limpeza,
           sum(valor) filter (where categoria = 'outros')  outros
    from dia_custos where data = d.data) dc on true
  left join lateral (select sum(cabecas_pagantes) cabecas from lotes where data = d.data) l on true
) x;

create view v_custo_lote with (security_invoker = true) as
select
  l.id as lote_id, l.codigo, l.data, l.cooperado_id, l.cabecas_pagantes,
  round(cd.custo_total / nullif(cd.cabecas_dia, 0), 4)                        as custo_por_cabeca,
  round(cd.custo_total * l.cabecas_pagantes / nullif(cd.cabecas_dia, 0), 2)   as custo_lote
from lotes l
join v_custo_dia cd on cd.data = l.data;

create or replace function fechar_dia(p_data date) returns void
language plpgsql set search_path = public as $$
declare d dias_producao; c v_custo_dia; n integer; soma numeric; ultimo bigint;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  select * into d from dias_producao where data = p_data for update;
  if not found then raise exception 'O dia não está aberto.'; end if;
  if d.fechado then raise exception 'O dia já está fechado.'; end if;
  if exists (select 1 from competencias where competencia = d.competencia and fechada) then
    raise exception 'O mês deste dia já foi fechado.';
  end if;
  if d.energia_ini is null or d.energia_fim is null or d.agua_ini is null or d.agua_fim is null then
    raise exception 'Informe as leituras inicial e final de energia e de água antes de fechar o dia.';
  end if;
  if not exists (select 1 from dia_diaristas where data = p_data) then
    raise exception 'Lance os diaristas do dia antes de fechar.';
  end if;
  select count(*) into n from lotes where data = p_data;
  if n = 0 then raise exception 'Não há lotes neste dia.'; end if;
  select count(*) into n from lotes where data = p_data and status <> 'finalizado';
  if n > 0 then raise exception 'Há % lote(s) ainda não finalizado(s).', n; end if;

  select * into c from v_custo_dia where data = p_data;
  if c.cabecas_dia <= 0 then raise exception 'O dia não tem cabeças pagantes.'; end if;

  update dias_producao set fechado = true, fechado_em = now(),
    f_diaristas = c.custo_diaristas, f_energia = c.custo_energia, f_agua = c.custo_agua,
    f_limpeza = c.custo_limpeza, f_outros = c.custo_outros, f_mensal = null, f_despesas = null,
    f_estrutura = c.custo_estrutura, f_cabecas = c.cabecas_dia
  where data = p_data
  returning f_diaristas + f_energia + f_agua + f_limpeza + f_outros + f_estrutura into soma;
  update dias_producao set f_total = soma where data = p_data;

  update lotes set custo_cabeca_fechado = round(soma / c.cabecas_dia, 4),
                   custo_fechado = round(soma * cabecas_pagantes / c.cabecas_dia, 2)
  where data = p_data;
  select id into ultimo from lotes where data = p_data order by ordem desc limit 1;
  update lotes set custo_fechado = custo_fechado + (soma - (select sum(custo_fechado) from lotes where data = p_data))
  where id = ultimo;
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
  update lotes set custo_fechado = null, custo_cabeca_fechado = null where data = p_data;
end $$;

-- Fechar o mês: apura a estrutura real, compara com o arrecadado e grava a taxa do mês seguinte
drop function if exists fechar_mes(date);
create function fechar_mes(p_comp date) returns jsonb
language plpgsql set search_path = public as $$
declare v_prox date := (p_comp + interval '1 month')::date; c competencias; n integer;
        v_mens numeric; v_desp numeric; v_ea numeric; v_en numeric; v_ag numeric; v_arr numeric; v_cab bigint;
        v_real numeric; v_pend numeric; v_alvo numeric; v_taxa numeric;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  insert into competencias (competencia) values (p_comp) on conflict do nothing;
  select * into c from competencias where competencia = p_comp for update;
  if c.fechada then raise exception 'Este mês já está fechado.'; end if;
  select count(*) into n from dias_producao where competencia = p_comp and not fechado;
  if n > 0 then raise exception 'Há % dia(s) de produção ainda aberto(s) neste mês. Feche-os antes de fechar o mês.', n; end if;

  select coalesce(sum(salario_mensal), 0) into v_mens from funcionarios where vinculo = 'fixo' and ativo;
  select coalesce(sum(d.valor), 0) into v_desp from despesas d join despesa_categorias k on k.id = d.categoria_id
    where k.rateia and d.data >= p_comp and d.data < v_prox;
  select coalesce(sum(f_energia), 0), coalesce(sum(f_agua), 0),
         coalesce(sum(coalesce(f_estrutura, coalesce(f_mensal, 0) + coalesce(f_despesas, 0))), 0), coalesce(sum(f_cabecas), 0)
    into v_en, v_ag, v_arr, v_cab from dias_producao where competencia = p_comp;
  -- energia e água fora dos dias de abate: só entra a conta que foi informada
  v_ea := (case when c.energia_conta_valor is not null then c.energia_conta_valor - v_en else 0 end)
        + (case when c.agua_conta_valor is not null then c.agua_conta_valor - v_ag else 0 end);
  v_real := v_mens + v_desp + v_ea;
  v_pend := c.alvo_estrutura - v_arr;          -- o que a taxa deste mês deixou de recuperar (negativo = sobrou)
  v_alvo := v_real + v_pend;                   -- o que a taxa do mês seguinte precisa recuperar
  if v_cab > 0 then v_taxa := greatest(round(v_alvo / v_cab, 6), 0); else v_taxa := coalesce(c.taxa_estrutura, 0); end if;

  update competencias set fechada = true, est_mensalistas = v_mens, est_despesas = v_desp, est_energia_agua = v_ea,
    est_real = v_real, est_arrecadado = v_arr, est_cabecas = v_cab, est_pendente = v_pend
  where competencia = p_comp;
  insert into competencias (competencia, taxa_estrutura, alvo_estrutura) values (v_prox, v_taxa, v_alvo)
    on conflict (competencia) do update set taxa_estrutura = excluded.taxa_estrutura, alvo_estrutura = excluded.alvo_estrutura;
  return jsonb_build_object('taxa', v_taxa, 'estrutura_real', v_real, 'arrecadado', v_arr, 'pendente', v_pend, 'alvo', v_alvo, 'cabecas', v_cab);
end $$;

create or replace function reabrir_mes(p_comp date) returns void
language plpgsql set search_path = public as $$
begin
  if not usuario_admin() then raise exception 'Só o administrador pode reabrir um mês fechado.'; end if;
  update competencias set fechada = false, est_mensalistas = null, est_despesas = null, est_energia_agua = null,
    est_real = null, est_arrecadado = null, est_cabecas = null, est_pendente = null
  where competencia = p_comp;
  update competencias set taxa_estrutura = null, alvo_estrutura = 0 where competencia = (p_comp + interval '1 month')::date;
end $$;

revoke execute on function fechar_mes(date), reabrir_mes(date) from public, anon;
grant execute on function fechar_mes(date), reabrir_mes(date) to authenticated;
