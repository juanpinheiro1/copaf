-- COPAF - Abatedouro | Pesagem de saída conjunta (definido em 13/11/2026).
--   Lotes do mesmo dia (cada um com a sua GTA) podem ser pesados juntos na saída.
--   O lote ganha o campo "pesar_com": o primeiro lote do grupo. A pesagem é lançada uma vez para o grupo
--   (pesagens_conjuntas) e a plataforma divide cada peso entre os lotes pela proporção de cabeças pagantes,
--   gravando as partes em lote_pesagens (câmara, painel, SIE e relatórios continuam lendo por lote).
--   Se as cabeças mudarem (condenações, mortos, caixas) ou um lote entrar/sair do grupo, a divisão é refeita.
--   Agrupamento livre: qualquer lote do dia, de qualquer cooperado.

begin;

alter table lotes add column pesar_com bigint references lotes on delete restrict;
create index on lotes (pesar_com);

create table pesagens_conjuntas (
  id           bigint generated always as identity primary key,
  grupo_lote_id bigint not null references lotes on delete cascade,   -- primeiro lote do grupo
  produto      text not null references produtos,
  conservacao  text not null default 'resfriado' check (conservacao in ('resfriado', 'congelado')),
  peso_kg      numeric(10,2) not null check (peso_kg > 0),
  volumes      integer check (volumes > 0),
  observacao   text,
  criado_em    timestamptz not null default now(),
  criado_por   text default lower(auth.jwt() ->> 'email')
);
create index on pesagens_conjuntas (grupo_lote_id);
alter table pesagens_conjuntas enable row level security;
create policy autorizados_all on pesagens_conjuntas for all to authenticated using (usuario_autorizado()) with check (usuario_autorizado());
grant select, insert, update, delete on pesagens_conjuntas to authenticated;

alter table lote_pesagens add column conjunta_id bigint references pesagens_conjuntas on delete cascade;
create index on lote_pesagens (conjunta_id);

-- regras do grupo: mesmo dia, um nível só (o lote indicado não pode estar em outro grupo)
create or replace function lotes_valida_grupo() returns trigger language plpgsql as $$
declare g lotes%rowtype;
begin
  if new.pesar_com is null then return new; end if;
  if new.pesar_com = new.id then raise exception 'O lote não pode ser pesado junto com ele mesmo.'; end if;
  select * into g from lotes where id = new.pesar_com;
  if g.data <> new.data then raise exception 'Só é possível pesar junto com um lote do mesmo dia.'; end if;
  if g.pesar_com is not null then raise exception 'O lote % já faz parte de outro grupo; escolha o primeiro lote do grupo.', g.codigo; end if;
  if tg_op = 'UPDATE' and exists (select 1 from lotes where pesar_com = new.id) then
    raise exception 'Este lote é o primeiro de um grupo de pesagem; ele não pode ser ligado a outro lote.'; end if;
  return new;
end $$;
create trigger lotes_valida_grupo before insert or update of pesar_com, data on lotes for each row execute function lotes_valida_grupo();

-- refaz as partes de cada pesagem conjunta do grupo, pela proporção de cabeças pagantes (o último lote acerta os centavos)
create or replace function redistribuir_pesagem(p_grupo bigint) returns void language plpgsql as $$
declare c record; m record; tot numeric; n int; i int; resto_kg numeric; resto_vol int; kg numeric; vol int;
begin
  if p_grupo is null then return; end if;
  delete from lote_pesagens where conjunta_id in (select id from pesagens_conjuntas where grupo_lote_id = p_grupo);
  select coalesce(sum(greatest(cabecas_pagantes, 0)), 0), count(*) into tot, n from lotes where id = p_grupo or pesar_com = p_grupo;
  if n = 0 then return; end if;
  for c in select * from pesagens_conjuntas where grupo_lote_id = p_grupo order by id loop
    i := 0; resto_kg := c.peso_kg; resto_vol := c.volumes;
    for m in select id, greatest(cabecas_pagantes, 0) as cab from lotes where id = p_grupo or pesar_com = p_grupo order by ordem, id loop
      i := i + 1;
      if i = n then kg := resto_kg; vol := resto_vol;
      else
        kg := round(c.peso_kg * (case when tot > 0 then m.cab / tot else 1.0 / n end), 2);
        vol := case when c.volumes is null then null else round(c.volumes * (case when tot > 0 then m.cab / tot else 1.0 / n end))::int end;
        resto_kg := resto_kg - kg; resto_vol := resto_vol - coalesce(vol, 0);
      end if;
      if kg > 0 then
        insert into lote_pesagens (lote_id, produto, conservacao, peso_kg, volumes, observacao, criado_em, criado_por, conjunta_id)
        values (m.id, c.produto, c.conservacao, kg, case when vol > 0 then vol end, c.observacao, c.criado_em, c.criado_por, c.id);
      end if;
    end loop;
  end loop;
end $$;

create or replace function pesagens_conjuntas_redistribuir() returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform redistribuir_pesagem(old.grupo_lote_id); end if;
  if tg_op in ('INSERT', 'UPDATE') then perform redistribuir_pesagem(new.grupo_lote_id); end if;
  return null;
end $$;
create trigger pesagens_conjuntas_redistribuir after insert or update or delete on pesagens_conjuntas for each row execute function pesagens_conjuntas_redistribuir();

create or replace function lotes_redistribuir() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then perform redistribuir_pesagem(new.pesar_com); return null; end if;
  if tg_op = 'DELETE' then perform redistribuir_pesagem(old.pesar_com); return null; end if;
  if old.cabecas_pagantes is distinct from new.cabecas_pagantes or old.pesar_com is distinct from new.pesar_com or old.ordem is distinct from new.ordem then
    perform redistribuir_pesagem(coalesce(old.pesar_com, old.id));
    if coalesce(new.pesar_com, new.id) <> coalesce(old.pesar_com, old.id) then perform redistribuir_pesagem(coalesce(new.pesar_com, new.id)); end if;
  end if;
  return null;
end $$;
create trigger lotes_redistribuir after insert or update or delete on lotes for each row execute function lotes_redistribuir();

grant execute on function redistribuir_pesagem(bigint) to authenticated;

commit;

select 'ok' as migracao_016, (select count(*) from lotes where pesar_com is not null) as lotes_agrupados;
