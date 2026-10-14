-- COPAF - Abatedouro | Despesas do dia a dia, caixa interno e taxa de despesas por cabeça.
-- Regra (13/10/2026): ao fechar o mês, total de despesas rateáveis ÷ cabeças abatidas no mês
-- = valor por cabeça que entra no custo de cada dia de produção do mês seguinte.

-- ───────── Categorias e despesas ─────────
create table despesa_categorias (
  id     bigint generated always as identity primary key,
  nome   text not null unique,
  rateia boolean not null default true,   -- entra no rateio por cabeça do mês seguinte
  ativo  boolean not null default true
);
insert into despesa_categorias (nome) values
  ('Manutenção'), ('Produtos de limpeza'), ('EPI e uniformes'), ('Gás / lenha da caldeira'), ('Gelo'),
  ('Combustível'), ('Material de escritório'), ('Alimentação'), ('Serviços de terceiros'), ('Taxas e impostos'), ('Outros');

create table despesas (
  id               bigint generated always as identity primary key,
  data             date not null,
  categoria_id     bigint not null references despesa_categorias,
  descricao        text not null,
  fornecedor       text,
  valor            numeric(12,2) not null check (valor > 0),
  fonte            text not null check (fonte in ('caixa', 'outra')),   -- caixa interno ou outra fonte
  forma_pagamento  text,
  documento        text,
  comprovante_path text,
  criado_em        timestamptz not null default now(),
  criado_por       text default lower(auth.jwt() ->> 'email')
);
create index on despesas (data);

-- ───────── Caixa interno: aportes e devoluções; as saídas são as despesas pagas pelo caixa ─────────
create table caixa_movimentos (
  id         bigint generated always as identity primary key,
  data       date not null,
  tipo       text not null check (tipo in ('aporte', 'devolucao')),
  valor      numeric(12,2) not null check (valor > 0),
  descricao  text,
  criado_em  timestamptz not null default now(),
  criado_por text default lower(auth.jwt() ->> 'email')
);

do $$
declare t text;
begin
  foreach t in array array['despesa_categorias', 'despesas', 'caixa_movimentos']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy autorizados_all on %I for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado())', t);
  end loop;
end $$;

-- Mês fechado não aceita mais lançar, alterar ou excluir despesa
create function despesas_mes_aberto() returns trigger
language plpgsql set search_path = public as $$
declare d date;
begin
  if tg_op = 'DELETE' then d := old.data; else d := new.data; end if;
  if exists (select 1 from competencias where competencia = date_trunc('month', d::timestamp)::date and fechada) then
    raise exception 'O mês % já foi fechado; as despesas dele não podem mais ser alteradas.', to_char(d, 'MM/YYYY');
  end if;
  if tg_op = 'UPDATE' and exists (select 1 from competencias where competencia = date_trunc('month', old.data::timestamp)::date and fechada) then
    raise exception 'O mês % já foi fechado; as despesas dele não podem mais ser alteradas.', to_char(old.data, 'MM/YYYY');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger despesas_mes_aberto before insert or update or delete on despesas
  for each row execute function despesas_mes_aberto();

-- ───────── Taxa de despesas por cabeça ─────────
alter table competencias
  add column taxa_despesas numeric(12,6),   -- R$ por cabeça aplicado NESTE mês (vem do mês anterior)
  add column despesas_base numeric(12,2),   -- total de despesas rateáveis do mês anterior
  add column cabecas_base  integer;         -- cabeças abatidas no mês anterior
alter table dias_producao add column f_despesas numeric(12,2);

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
    + (coalesce(cm.previsto, 0) + coalesce(fx.total, 0)) / coalesce(c.dias_abate_previstos, 15)
    + round(coalesce(c.taxa_despesas, 0) * coalesce(l.cabecas, 0), 2) as custo_total,
  round(coalesce(c.taxa_despesas, 0) * coalesce(l.cabecas, 0), 2)    as custo_despesas
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

-- Fechar o dia passa a gravar também a parcela de despesas do mês anterior
create or replace function fechar_dia(p_data date) returns void
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
    f_despesas = c.custo_despesas, f_cabecas = c.cabecas_dia
  where data = p_data
  returning f_diaristas + f_energia + f_agua + f_limpeza + f_outros + f_mensal + f_despesas into soma;
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
  update dias_producao set fechado = false, fechado_em = null, f_diaristas = null, f_energia = null, f_agua = null,
    f_limpeza = null, f_outros = null, f_mensal = null, f_despesas = null, f_total = null, f_cabecas = null
  where data = p_data;
  update lotes set custo_fechado = null, custo_cabeca_fechado = null where data = p_data;
end $$;

-- Fechar o mês: trava as despesas e grava no mês seguinte a taxa por cabeça
create function fechar_mes(p_comp date) returns numeric
language plpgsql set search_path = public as $$
declare v_total numeric; v_cab bigint; v_taxa numeric; v_prox date := (p_comp + interval '1 month')::date;
begin
  if not usuario_autorizado() then raise exception 'Sem permissão.'; end if;
  insert into competencias (competencia) values (p_comp) on conflict do nothing;
  if (select fechada from competencias where competencia = p_comp) then raise exception 'Este mês já está fechado.'; end if;
  select coalesce(sum(d.valor), 0) into v_total from despesas d join despesa_categorias c on c.id = d.categoria_id
    where c.rateia and d.data >= p_comp and d.data < v_prox;
  select coalesce(sum(cabecas_pagantes), 0) into v_cab from lotes where data >= p_comp and data < v_prox;
  if v_cab = 0 and v_total > 0 then
    raise exception 'O mês não teve aves abatidas; não há como ratear R$ % de despesas por cabeça.', v_total;
  end if;
  v_taxa := case when v_cab > 0 then round(v_total / v_cab, 6) else 0 end;
  insert into competencias (competencia, taxa_despesas, despesas_base, cabecas_base) values (v_prox, v_taxa, v_total, v_cab)
    on conflict (competencia) do update set taxa_despesas = excluded.taxa_despesas, despesas_base = excluded.despesas_base, cabecas_base = excluded.cabecas_base;
  update competencias set fechada = true where competencia = p_comp;
  return v_taxa;
end $$;

create function reabrir_mes(p_comp date) returns void
language plpgsql set search_path = public as $$
begin
  if not usuario_admin() then raise exception 'Só o administrador pode reabrir um mês fechado.'; end if;
  update competencias set fechada = false where competencia = p_comp;
  update competencias set taxa_despesas = null, despesas_base = null, cabecas_base = null
    where competencia = (p_comp + interval '1 month')::date;
end $$;

revoke execute on function fechar_mes(date), reabrir_mes(date) from public, anon;
grant execute on function fechar_mes(date), reabrir_mes(date) to authenticated;

-- ───────── Comprovantes (fotos de notas e recibos) ─────────
insert into storage.buckets (id, name, public) values ('comprovantes', 'comprovantes', false) on conflict (id) do nothing;
create policy comprovantes_autorizados on storage.objects for all to authenticated
  using (bucket_id = 'comprovantes' and public.usuario_autorizado())
  with check (bucket_id = 'comprovantes' and public.usuario_autorizado());
