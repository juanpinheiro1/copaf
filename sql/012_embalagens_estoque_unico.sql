-- COPAF - Abatedouro | Embalagens passam a ser um estoque único da cooperativa (14/10/2026).
-- Antes cada cooperado tinha a sua lista. A baixa continua sendo lançada por lote.
-- Na data desta mudança a tabela de embalagens estava vazia.

drop view if exists v_embalagem_saldo;
alter table embalagens drop column cooperado_id;   -- leva junto a regra "nome único por cooperado"
alter table embalagens add constraint embalagens_nome_key unique (nome);

create view v_embalagem_saldo with (security_invoker = true) as
select e.id as embalagem_id, e.nome, e.estoque_minimo, e.ativo,
       coalesce(sum(m.quantidade) filter (where m.tipo = 'entrada'), 0) as entradas,
       coalesce(sum(m.quantidade) filter (where m.tipo = 'saida'), 0)   as saidas,
       coalesce(sum(case m.tipo when 'entrada' then m.quantidade when 'saida' then -m.quantidade end), 0) as saldo
from embalagens e
left join embalagem_movimentos m on m.embalagem_id = e.id
group by e.id;
