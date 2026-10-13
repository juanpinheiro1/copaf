-- FORT AVES - Abatedouro | Etiquetas de produto e relatórios do SIE.

-- ───────── Origem das aves (Mapa de Abate e Ocorrências Sanitárias) ─────────
alter table cooperados add column municipio text, add column uf text default 'PB', add column propriedade text;
alter table lotes add column gta text, add column municipio_origem text, add column uf_origem text, add column propriedade text;

-- ───────── Condenações totais por enfermidade ─────────
create table lote_condenacoes (
  id          bigint generated always as identity primary key,
  lote_id     bigint not null references lotes on delete cascade,
  enfermidade text not null,
  quantidade  integer not null check (quantidade > 0),
  criado_em   timestamptz not null default now()
);
create index on lote_condenacoes (lote_id);

-- Com detalhamento por enfermidade, o total de condenadas do lote passa a ser a soma das linhas
create function sync_condenadas() returns trigger
language plpgsql set search_path = public as $$
declare v bigint;
begin
  if tg_op = 'DELETE' then v := old.lote_id; else v := new.lote_id; end if;
  update lotes set condenadas = coalesce((select sum(quantidade) from lote_condenacoes where lote_id = v), 0) where id = v;
  return null;
end $$;
create trigger lote_condenacoes_sync after insert or update or delete on lote_condenacoes
  for each row execute function sync_condenadas();

-- ───────── Dados do estabelecimento (cabeçalho dos relatórios) ─────────
create table estabelecimento (
  id                 integer primary key default 1 check (id = 1),
  razao_social       text, sigla text, cnpj text, inscricao_estadual text,
  registro_sie       text, registro_crmv text, endereco text,
  municipio_abate    text, uf text, ulsav text, especie text,
  rt_nome            text, rt_titulo text, rt_crmv text
);
insert into estabelecimento (id, razao_social, sigla, cnpj, inscricao_estadual, registro_sie, registro_crmv, endereco,
                             municipio_abate, uf, especie, rt_nome, rt_titulo, rt_crmv)
values (1, 'Cooperativa Paraibana de Avicultura e Agricultura Familiar', 'COPAF', '09.403.048/0001-15', '16.159.482-4',
        '196.01.00226', 'PB 01008 PJ', 'Sítio Turuatha, s/n, Zona Rural, São Sebastião de Lagoa de Roça-PB, CEP 58.119-000',
        'São Sebastião de Lagoa de Roça', 'PB', 'Aves', 'Jean Charles da Silva Dias', 'Médico Veterinário - Responsável Técnico', '00781/PB');

-- ───────── Etiquetas por produto ─────────
create table etiquetas (
  produto                  text primary key references produtos,
  nome_impresso            text not null,
  peso_liquido             text not null default '1 Kg',
  porcoes_emb              text,
  porcao_g                 numeric(8,2),
  porcao_desc              text,
  nutrientes               jsonb not null default '{}',   -- { chave: { v100, vd } }
  validade_resfriado_dias  integer,
  validade_congelado_dias  integer default 365,
  ean                      text
);
create table etiqueta_eans (
  cooperado_id bigint not null references cooperados on delete cascade,
  produto      text not null references produtos,
  ean          text not null,
  primary key (cooperado_id, produto)
);
-- Modelo atual da etiqueta de sobrecoxa (porção de 62 g; % VD como consta na etiqueta em uso)
insert into etiquetas (produto, nome_impresso, peso_liquido, porcoes_emb, porcao_g, porcao_desc, nutrientes)
values ('sobrecoxa', 'SOBRECOXA', '1 Kg', 'cerca de 10', 62, '1 Fração',
  '{"energia":{"v100":194,"vd":10},"carboidratos":{"v100":0,"vd":0},"acucares_totais":{"v100":0,"vd":0},"acucares_adicionados":{"v100":0,"vd":0},"proteinas":{"v100":17,"vd":34},"gorduras_totais":{"v100":14,"vd":22},"gorduras_saturadas":{"v100":3.5,"vd":18},"gorduras_trans":{"v100":0,"vd":0},"fibras":{"v100":0,"vd":0},"sodio":{"v100":82,"vd":4}}');

do $$
declare t text;
begin
  foreach t in array array['lote_condenacoes', 'estabelecimento', 'etiquetas', 'etiqueta_eans']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy autorizados_all on %I for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado())', t);
  end loop;
end $$;
