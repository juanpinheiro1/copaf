-- FORT AVES - Abatedouro | O dia de produção abre sem o mês estar preenchido.
-- A competência é criada vazia ao abrir o dia; enquanto não houver dias de abate previstos
-- e custos fixos mensais, a diária dos custos mensais entra como zero e as telas avisam.
alter table competencias alter column dias_abate_previstos drop not null;
