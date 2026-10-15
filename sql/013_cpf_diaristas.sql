-- COPAF - Abatedouro | CPF da equipe e endereço da unidade industrial,
-- usados no "Controle de pagamento do abate" (lista de diaristas do dia para assinatura).

alter table funcionarios add column cpf text;
alter table estabelecimento add column endereco_industrial text;
update estabelecimento
   set endereco = 'Sítio Turuatha, s/n, Zona Rural, São Sebastião de Lagoa de Roça-PB, CEP 58.119-000',
       endereco_industrial = 'BR 104, Km 106,4, Zona Rural, São Sebastião de Lagoa de Roça-PB, CEP 58.119-000'
 where id = 1;
