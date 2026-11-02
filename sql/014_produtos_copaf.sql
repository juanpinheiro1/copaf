-- COPAF - Abatedouro | Lista de produtos da pesagem igual à ficha "RETIRADA E PRODUÇÃO" da COPAF (02/11/2026).
-- Os produtos que já existiam e têm o mesmo significado só mudam de nome (o código e o histórico continuam).
-- "Frango inteiro com miúdos / Galeto" genérico fica inativo: some da pesagem nova, mas o histórico continua.

alter table produtos add column ativo boolean not null default true;

-- produtos existentes, com o nome da ficha, na ordem da ficha
update produtos p set nome = v.nome, ordem = v.ordem
from (values
  ('peito_osso',     'PEITO A GRANEL',                          10),
  ('file_peito',     'FILÉ DE PEITO A GRANEL',                  11),
  ('sassami',        'FILEZINHO DE PEITO (SASSAMI) A GRANEL',   12),
  ('coxa_sobrecoxa', 'COXA E S/ COXA A GRANEL',                 13),
  ('coxa',           'COXA A GRANEL',                           14),
  ('sobrecoxa',      'SOBRECOXA A GRANEL',                      15),
  ('asa_completa',   'ASA E COXINHA (ASA COMP) A GRANEL',       17),
  ('asa',            'ASA A GRANEL',                            18),
  ('coxinha_asa',    'COXINHA DA ASA A GRANEL',                 19),
  ('meio_asa',       'MEIO DA ASA (TULIPA) A GRANEL',           20),
  ('moela',          'MOELA A GRANEL',                          21),
  ('coracao',        'CORAÇÃO A GRANEL',                        22),
  ('figado',         'FÍGADO A GRANEL',                         23),
  ('pescoco',        'PESCOÇO A GRANEL',                        24),
  ('pe',             'PÉ A GRANEL',                             25),
  ('dorso',          'CANJA A GRANEL',                          26)
) as v(codigo, nome, ordem)
where p.codigo = v.codigo;

update produtos set ativo = false, ordem = 99, nome = 'FRANGO INTEIRO C/ MIÚDOS (genérico, antigo)' where codigo = 'inteiro_miudos';

-- produtos novos
insert into produtos (codigo, nome, ordem) values
  ('frango_1_3',            'FRANGO 1.3',                                 1),
  ('frango_1_4',            'FRANGO 1.4',                                 2),
  ('frango_1_5',            'FRANGO 1.5',                                 3),
  ('frango_1_6',            'FRANGO 1.6',                                 4),
  ('frango_1_7',            'FRANGO 1.7',                                 5),
  ('frango_1_8',            'FRANGO 1.8',                                 6),
  ('inteiro_transparente',  'FRANGO INTEIRO C/ MIÚDO TRANSPARENTE',       7),
  ('inteiro_fortaves',      'FRANGO INTEIRO C/ MIÚDO FORTAVES',           8),
  ('frango_caipira',        'FRANGO CAIPIRA',                             9),
  ('file_coxa',             'FILÉ DE COXA (DESOSSADA) A GRANEL',         16),
  ('peito_bdj',             'PEITO BANDEJA',                             27),
  ('file_peito_bdj',        'FILÉ DE PEITO BANDEJA',                     28),
  ('sassami_bdj',           'FILEZINHO DE PEITO (SASSAMI) BANDEJA',      29),
  ('coxa_sobrecoxa_bdj',    'COXA E S/COXA BANDEJA',                     30),
  ('coxa_bdj',              'COXA BANDEJA',                              31),
  ('sobrecoxa_bdj',         'SOBRECOXA BANDEJA',                         32),
  ('file_coxa_bdj',         'FILÉ DE COXA (DESOSSADA) BANDEJA',          33),
  ('asa_completa_bdj',      'ASA E COXINHA (ASA COMP) BANDEJA',          34),
  ('asa_bdj',               'ASA BANDEJA',                               35),
  ('coxinha_asa_bdj',       'COXINHA DA ASA BANDEJA',                    36),
  ('meio_asa_bdj',          'MEIO DA ASA (TULIPA) BANDEJA',              37),
  ('coracao_bdj',           'CORAÇÃO BANDEJA',                           38),
  ('figado_bdj',            'FÍGADO BANDEJA',                            39),
  ('moela_bdj',             'MOELA BANDEJA',                             40),
  ('pe_bdj',                'PÉ BANDEJA',                                41);

select count(*) filter (where ativo) as ativos, count(*) filter (where not ativo) as inativos from produtos;
