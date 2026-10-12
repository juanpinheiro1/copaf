-- FORT AVES - Abatedouro | Status do lote, fechamento do dia com custo congelado,
-- produtos, rendimentos por tipo de ave e plano de cortes do lote.

-- ───────── Status do lote e custo congelado ─────────
alter table lotes
  add column status text not null default 'aberto' check (status in ('aberto', 'em_producao', 'finalizado')),
  add column finalizado_em timestamptz,
  add column custo_fechado numeric(12,2),
  add column custo_cabeca_fechado numeric(12,4);

alter table dias_producao
  add column f_diaristas numeric(12,2), add column f_energia numeric(12,2), add column f_agua numeric(12,2),
  add column f_limpeza numeric(12,2),  add column f_outros numeric(12,2),  add column f_mensal numeric(12,2),
  add column f_total numeric(12,2),    add column f_cabecas integer;

-- ───────── Produtos e rendimentos (% do peso vivo) ─────────
create table produtos (
  codigo text primary key,
  nome   text not null,
  ordem  integer not null
);
insert into produtos (codigo, nome, ordem) values
  ('inteiro_miudos', 'Frango inteiro com miúdos / Galeto', 1),
  ('peito_osso',     'Peito com osso', 2),
  ('file_peito',     'Filé de peito', 3),
  ('sassami',        'Sassami', 4),
  ('coxa_sobrecoxa', 'Coxa e sobrecoxa', 5),
  ('coxa',           'Coxa', 6),
  ('sobrecoxa',      'Sobrecoxa', 7),
  ('asa_completa',   'Asa completa (com ponta)', 8),
  ('asa',            'Asa (sem ponta)', 9),
  ('coxinha_asa',    'Coxinha da asa (tulipa)', 10),
  ('meio_asa',       'Meio da asa', 11),
  ('dorso',          'Canja (dorso)', 12),
  ('figado',         'Fígado', 13),
  ('moela',          'Moela', 14),
  ('coracao',        'Coração', 15),
  ('pescoco',        'Pescoço', 16),
  ('pe',             'Pé', 17);

create table rendimentos (
  tipo_ave text not null references tipos_ave,
  produto  text not null references produtos,
  pct      numeric(6,3) not null check (pct >= 0 and pct <= 100),
  primary key (tipo_ave, produto)
);
-- Referência: Cobb500 Broiler Yield (Cobb-Vantress, L-064-02-2022), % do peso vivo, ave de 2,73 kg,
-- rendimento seco (antes do chiller). Conferida com Embrapa Suínos e Aves (Ross, 42 dias).
-- Os três tipos de ave começam iguais; galetinho e caipira devem ser calibrados pelo abatedouro.
insert into rendimentos (tipo_ave, produto, pct)
select t.codigo, v.produto, v.pct
from tipos_ave t cross join (values
  ('inteiro_miudos', 84.52), ('peito_osso', 36.35), ('file_peito', 22.05), ('sassami', 4.00),
  ('coxa_sobrecoxa', 23.01), ('coxa', 9.35), ('sobrecoxa', 13.66),
  ('asa_completa', 7.58), ('asa', 6.65), ('coxinha_asa', 3.91), ('meio_asa', 2.74),
  ('dorso', 8.61), ('figado', 1.64), ('moela', 1.04), ('coracao', 0.29), ('pescoco', 3.50), ('pe', 2.50)
) as v(produto, pct);

-- ───────── Plano de cortes do lote ─────────
create table lote_planos (
  id          bigint generated always as identity primary key,
  lote_id     bigint not null references lotes on delete cascade,
  aves        integer not null check (aves > 0),
  destino     text not null check (destino in ('inteiro', 'cortes')),
  peito       text check (peito in ('com_osso', 'file')),
  perna       text check (perna in ('junta', 'separada')),
  asa         text check (asa in ('completa', 'sem_ponta', 'tulipa_meio')),
  dorso       boolean not null default false,
  miudos      text[] not null default '{}',
  conservacao text not null default 'resfriado' check (conservacao in ('resfriado', 'congelado')),
  observacao  text
);
create index on lote_planos (lote_id);

do $$
declare t text;
begin
  foreach t in array array['produtos', 'rendimentos', 'lote_planos']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy autorizados_all on %I for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado())', t);
  end loop;
end $$;

-- ───────── Fechar e reabrir o dia ─────────
-- Fechar exige leituras inicial e final dos medidores, diaristas lançados e todos os lotes finalizados.
-- O custo do dia e de cada lote fica gravado; o que mudar depois vai para o complemento mensal.
create function fechar_dia(p_data date) returns void
language plpgsql set search_path = public as $$
declare d dias_producao; c v_custo_dia; n integer; soma numeric; ultimo bigint;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  select * into d from dias_producao where data = p_data for update;
  if not found then raise exception 'O dia não está aberto.'; end if;
  if d.fechado then raise exception 'O dia já está fechado.'; end if;
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
    f_limpeza = c.custo_limpeza, f_outros = c.custo_outros, f_mensal = c.parcela_custos_mensais,
    f_cabecas = c.cabecas_dia
  where data = p_data
  returning f_diaristas + f_energia + f_agua + f_limpeza + f_outros + f_mensal into soma;
  update dias_producao set f_total = soma where data = p_data;

  update lotes set custo_cabeca_fechado = round(soma / c.cabecas_dia, 4),
                   custo_fechado = round(soma * cabecas_pagantes / c.cabecas_dia, 2)
  where data = p_data;
  -- centavos de arredondamento ficam no último lote, para a soma dos lotes fechar com o dia
  select id into ultimo from lotes where data = p_data order by ordem desc limit 1;
  update lotes set custo_fechado = custo_fechado + (soma - (select sum(custo_fechado) from lotes where data = p_data))
  where id = ultimo;
end $$;

create function reabrir_dia(p_data date) returns void
language plpgsql set search_path = public as $$
begin
  if not usuario_admin() then raise exception 'Só o administrador pode reabrir um dia fechado.'; end if;
  update dias_producao set fechado = false, fechado_em = null, f_diaristas = null, f_energia = null, f_agua = null,
    f_limpeza = null, f_outros = null, f_mensal = null, f_total = null, f_cabecas = null
  where data = p_data;
  update lotes set custo_fechado = null, custo_cabeca_fechado = null where data = p_data;
end $$;

revoke execute on function fechar_dia(date), reabrir_dia(date) from public, anon;
grant execute on function fechar_dia(date), reabrir_dia(date) to authenticated;

-- ───────── Complemento mensal passa a usar o que foi cobrado nos dias fechados ─────────
-- Energia e água: conta real menos o cobrado. Custos fixos: diária que o dia fechado deixou de pagar
-- (dia fechado antes de os custos fixos do mês serem informados).
create or replace view v_complemento_mes with (security_invoker = true) as
select
  c.competencia,
  c.energia_conta_valor - coalesce(d.energia_cobrada, 0) as complemento_energia,
  c.agua_conta_valor    - coalesce(d.agua_cobrada, 0)    as complemento_agua,
  d.cabecas_mes,
  coalesce(d.fixos_pendentes, 0)                         as complemento_fixos
from competencias c
left join lateral (
  select sum(coalesce(dp.f_energia, v.custo_energia)) energia_cobrada,
         sum(coalesce(dp.f_agua, v.custo_agua))       agua_cobrada,
         sum(v.cabecas_dia)                           cabecas_mes,
         sum(case when dp.fechado then v.parcela_custos_mensais - coalesce(dp.f_mensal, 0) else 0 end) fixos_pendentes
  from v_custo_dia v join dias_producao dp on dp.data = v.data
  where v.competencia = c.competencia) d on true;

create or replace view v_complemento_cooperado with (security_invoker = true) as
select
  m.competencia, l.cooperado_id,
  sum(l.cabecas_pagantes) as cabecas,
  round((coalesce(m.complemento_energia, 0) + coalesce(m.complemento_agua, 0) + m.complemento_fixos)
        * sum(l.cabecas_pagantes) / nullif(m.cabecas_mes, 0), 2) as complemento
from v_complemento_mes m
join dias_producao d on d.competencia = m.competencia
join lotes l on l.data = d.data
group by m.competencia, l.cooperado_id, m.complemento_energia, m.complemento_agua, m.complemento_fixos, m.cabecas_mes;
