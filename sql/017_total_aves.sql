-- COPAF - Abatedouro | Total de aves informado na chegada (definido em 17/11/2026).
--   A contagem por caixas × aves por caixa vinha falhando (caixas com quantidades diferentes).
--   O lote passa a ter o campo aves_total (contado na chegada, obrigatório); aves_recebidas e
--   cabecas_pagantes passam a ser calculados a partir dele. Qtd. de caixas fica opcional, só informativa.
--   Aves por caixa e carcaças contadas saem da tela; as colunas ficam no banco como histórico.
--   Os lotes existentes recebem o total que já tinham (caixas × aves por caixa ou carcaças + mortos + condenadas),
--   então cabeças, custos e relatórios de outubro e novembro não mudam.

begin;

create temp table _antes on commit drop as select id, aves_recebidas, cabecas_pagantes from lotes;

alter table lotes add column aves_total integer check (aves_total > 0);
update lotes set aves_total = coalesce(qtd_caixas * aves_por_caixa, carcacas_contadas + mortos_chegada + condenadas);

-- a regra antiga (caixas e aves por caixa, ou carcaças contadas) deixa de valer
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'lotes'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%carcacas_contadas%' loop
    execute format('alter table lotes drop constraint %I', c);
  end loop;
end $$;

alter table lotes alter column aves_total set not null;
alter table lotes alter column aves_recebidas set expression as (aves_total);
alter table lotes alter column cabecas_pagantes set expression as (aves_total - mortos_chegada - condenadas);
alter table lotes add constraint lotes_mortos_condenadas_ate_total check (mortos_chegada + condenadas <= aves_total) not valid;

-- conferência: nenhum lote pode ter mudado de aves recebidas ou cabeças pagantes
do $$ declare n int; begin
  select count(*) into n from lotes l join _antes a using (id)
   where l.cabecas_pagantes is distinct from a.cabecas_pagantes or (a.aves_recebidas is not null and l.aves_recebidas <> a.aves_recebidas);
  if n > 0 then raise exception '% lote(s) mudariam de cabeças ou aves recebidas; migração cancelada.', n; end if;
end $$;

commit;

select 'ok' as migracao_017, count(*) as lotes, sum(aves_total) as aves, sum(cabecas_pagantes) as cabecas from lotes;
